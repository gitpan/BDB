#include "xthread.h"

#include <errno.h>

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

// perl stupidly defines these as macros, breaking
// lots and lots of code.
#undef open
#undef close
#undef abort
#undef malloc
#undef free
#undef send

#include <stddef.h>
#include <stdlib.h>
#include <errno.h>
#include <sys/types.h>
#include <limits.h>
#include <fcntl.h>

#ifndef _WIN32
# include <sys/time.h>
# include <unistd.h>
#endif

#include <db.h>

#if DB_VERSION_MAJOR < 4 || (DB_VERSION_MAJOR == 4 && DB_VERSION_MINOR < 4)
# error you need Berkeley DB 4.4 or newer installed
#endif

/* number of seconds after which idle threads exit */
#define IDLE_TIMEOUT 10

typedef DB_ENV      DB_ENV_ornull;
typedef DB_TXN      DB_TXN_ornull;
typedef DBC         DBC_ornull;
typedef DB          DB_ornull;
typedef DB_SEQUENCE DB_SEQUENCE_ornull;

typedef SV SV8; /* byte-sv, used for argument-checking */
typedef char *octetstring;

static SV *prepare_cb;

static void
debug_errcall (const DB_ENV *dbenv, const char *errpfx, const char *msg)
{
  printf ("err[%s]\n", msg);
}

static void
debug_msgcall (const DB_ENV *dbenv, const char *msg)
{
  printf ("msg[%s]\n", msg);
}

static char *
strdup_ornull (const char *s)
{
  return s ? strdup (s) : 0;
}

static void
sv_to_dbt (DBT *dbt, SV *sv)
{
  STRLEN len;
  char *data = SvPVbyte (sv, len);

  dbt->data = malloc (len);
  memcpy (dbt->data, data, len);
  dbt->size = len;
  dbt->flags = DB_DBT_REALLOC;
}
	
static void
dbt_to_sv (SV *sv, DBT *dbt)
{
  if (sv)
    {
      SvREADONLY_off (sv);
      sv_setpvn_mg (sv, dbt->data, dbt->size);
      SvREFCNT_dec (sv);
    }

  free (dbt->data);
}
	
enum {
  REQ_QUIT,
  REQ_ENV_OPEN, REQ_ENV_CLOSE, REQ_ENV_TXN_CHECKPOINT, REQ_ENV_LOCK_DETECT,
  REQ_ENV_MEMP_SYNC, REQ_ENV_MEMP_TRICKLE,
  REQ_DB_OPEN, REQ_DB_CLOSE, REQ_DB_COMPACT, REQ_DB_SYNC,
  REQ_DB_PUT, REQ_DB_GET, REQ_DB_PGET, REQ_DB_DEL, REQ_DB_KEY_RANGE,
  REQ_TXN_COMMIT, REQ_TXN_ABORT,
  REQ_C_CLOSE, REQ_C_COUNT, REQ_C_PUT, REQ_C_GET, REQ_C_PGET, REQ_C_DEL,
  REQ_SEQ_OPEN, REQ_SEQ_CLOSE, REQ_SEQ_GET, REQ_SEQ_REMOVE,
};

typedef struct aio_cb
{
  struct aio_cb *volatile next;
  SV *callback;
  int type, pri, result;

  DB_ENV *env;
  DB *db;
  DB_TXN *txn;
  DBC *dbc;

  UV uv1;
  int int1, int2;
  U32 uint1, uint2;
  char *buf1, *buf2;
  SV *sv1, *sv2, *sv3;

  DBT dbt1, dbt2, dbt3;
  DB_KEY_RANGE key_range;
  DB_SEQUENCE *seq;
  db_seq_t seq_t;
} aio_cb;

typedef aio_cb *aio_req;

enum {
  PRI_MIN     = -4,
  PRI_MAX     =  4,

  DEFAULT_PRI = 0,
  PRI_BIAS    = -PRI_MIN,
  NUM_PRI     = PRI_MAX + PRI_BIAS + 1,
};

#define AIO_TICKS ((1000000 + 1023) >> 10)

static unsigned int max_poll_time = 0;
static unsigned int max_poll_reqs = 0;

/* calculcate time difference in ~1/AIO_TICKS of a second */
static int tvdiff (struct timeval *tv1, struct timeval *tv2)
{
  return  (tv2->tv_sec  - tv1->tv_sec ) * AIO_TICKS
       + ((tv2->tv_usec - tv1->tv_usec) >> 10);
}

static int next_pri = DEFAULT_PRI + PRI_BIAS;

static unsigned int started, idle, wanted;

/* worker threads management */
static mutex_t wrklock = X_MUTEX_INIT;

typedef struct worker {
  /* locked by wrklock */
  struct worker *prev, *next;

  thread_t tid;

  /* locked by reslock, reqlock or wrklock */
  aio_req req; /* currently processed request */
  void *dbuf;
  DIR *dirp;
} worker;

static worker wrk_first = { &wrk_first, &wrk_first, 0 };

static void worker_clear (worker *wrk)
{
}

static void worker_free (worker *wrk)
{
  wrk->next->prev = wrk->prev;
  wrk->prev->next = wrk->next;

  free (wrk);
}

static volatile unsigned int nreqs, nready, npending;
static volatile unsigned int max_idle = 4;
static volatile unsigned int max_outstanding = 0xffffffff;
static int respipe [2], respipe_osf [2];

static mutex_t reslock = X_MUTEX_INIT;
static mutex_t reqlock = X_MUTEX_INIT;
static cond_t  reqwait = X_COND_INIT;

#if WORDACCESS_UNSAFE

static unsigned int get_nready ()
{
  unsigned int retval;

  X_LOCK   (reqlock);
  retval = nready;
  X_UNLOCK (reqlock);

  return retval;
}

static unsigned int get_npending ()
{
  unsigned int retval;

  X_LOCK   (reslock);
  retval = npending;
  X_UNLOCK (reslock);

  return retval;
}

static unsigned int get_nthreads ()
{
  unsigned int retval;

  X_LOCK   (wrklock);
  retval = started;
  X_UNLOCK (wrklock);

  return retval;
}

#else

# define get_nready()   nready
# define get_npending() npending
# define get_nthreads() started

#endif

/*
 * a somewhat faster data structure might be nice, but
 * with 8 priorities this actually needs <20 insns
 * per shift, the most expensive operation.
 */
typedef struct {
  aio_req qs[NUM_PRI], qe[NUM_PRI]; /* qstart, qend */
  int size;
} reqq;

static reqq req_queue;
static reqq res_queue;

int reqq_push (reqq *q, aio_req req)
{
  int pri = req->pri;
  req->next = 0;

  if (q->qe[pri])
    {
      q->qe[pri]->next = req;
      q->qe[pri] = req;
    }
  else
    q->qe[pri] = q->qs[pri] = req;

  return q->size++;
}

aio_req reqq_shift (reqq *q)
{
  int pri;

  if (!q->size)
    return 0;

  --q->size;

  for (pri = NUM_PRI; pri--; )
    {
      aio_req req = q->qs[pri];

      if (req)
        {
          if (!(q->qs[pri] = req->next))
            q->qe[pri] = 0;

          return req;
        }
    }

  abort ();
}

static int poll_cb ();
static void req_free (aio_req req);
static void req_cancel (aio_req req);

static int req_invoke (aio_req req)
{
  dSP;

  if (SvOK (req->callback))
    {
      ENTER;
      SAVETMPS;
      PUSHMARK (SP);

      switch (req->type)
        {
          case REQ_DB_CLOSE:
            SvREFCNT_dec (req->sv1);
            break;

          case REQ_DB_GET:
          case REQ_DB_PGET:
            dbt_to_sv (req->sv3, &req->dbt3);
            break;

          case REQ_C_GET:
          case REQ_C_PGET:
            dbt_to_sv (req->sv1, &req->dbt1);
            dbt_to_sv (req->sv2, &req->dbt2);
            dbt_to_sv (req->sv3, &req->dbt3);
            break;

          case REQ_DB_KEY_RANGE:
            {
              AV *av = newAV ();

              av_push (av, newSVnv (req->key_range.less));
              av_push (av, newSVnv (req->key_range.equal));
              av_push (av, newSVnv (req->key_range.greater));

              SvREADONLY_off (req->sv1);
              sv_setsv_mg (req->sv1, newRV_noinc ((SV *)av));
              SvREFCNT_dec (req->sv1);
            }
            break;

          case REQ_SEQ_GET:
            SvREADONLY_off (req->sv1);

            if (sizeof (IV) > 4)
              sv_setiv_mg (req->sv1, req->seq_t);
            else
              sv_setnv_mg (req->sv1, req->seq_t);

            SvREFCNT_dec (req->sv1);
            break;
        }

      errno = req->result;

      PUTBACK;
      call_sv (req->callback, G_VOID | G_EVAL);
      SPAGAIN;

      FREETMPS;
      LEAVE;
    }

  return !SvTRUE (ERRSV);
}

static void req_free (aio_req req)
{
  free (req->buf1);
  free (req->buf2);
  Safefree (req);
}

#ifdef USE_SOCKETS_AS_HANDLES
# define TO_SOCKET(x) (win32_get_osfhandle (x))
#else
# define TO_SOCKET(x) (x)
#endif

static void
create_pipe (int fd[2])
{
#ifdef _WIN32
  int arg = 1;
  if (PerlSock_socketpair (AF_UNIX, SOCK_STREAM, 0, fd)
      || ioctlsocket (TO_SOCKET (fd [0]), FIONBIO, &arg)
      || ioctlsocket (TO_SOCKET (fd [1]), FIONBIO, &arg))
#else
  if (pipe (fd)
      || fcntl (fd [0], F_SETFL, O_NONBLOCK)
      || fcntl (fd [1], F_SETFL, O_NONBLOCK))
#endif
    croak ("unable to initialize result pipe");

  respipe_osf [0] = TO_SOCKET (respipe [0]);
  respipe_osf [1] = TO_SOCKET (respipe [1]);
}

X_THREAD_PROC (bdb_proc);

static void start_thread (void)
{
  worker *wrk = calloc (1, sizeof (worker));

  if (!wrk)
    croak ("unable to allocate worker thread data");

  X_LOCK (wrklock);
  if (thread_create (&wrk->tid, bdb_proc, (void *)wrk))
    {
      wrk->prev = &wrk_first;
      wrk->next = wrk_first.next;
      wrk_first.next->prev = wrk;
      wrk_first.next = wrk;
      ++started;
    }
  else
    free (wrk);

  X_UNLOCK (wrklock);
}

static void maybe_start_thread ()
{
  if (get_nthreads () >= wanted)
    return;
  
  /* todo: maybe use idle here, but might be less exact */
  if (0 <= (int)get_nthreads () + (int)get_npending () - (int)nreqs)
    return;

  start_thread ();
}

static void req_send (aio_req req)
{
  SV *wait_callback = 0;

  // synthesize callback if none given
  if (!SvOK (req->callback))
    {
      int count;

      dSP;
      PUSHMARK (SP);
      PUTBACK;
      count = call_sv (prepare_cb, G_ARRAY);
      SPAGAIN;

      if (count != 2)
        croak ("prepare callback must return exactly two values\n");

      wait_callback = SvREFCNT_inc (POPs);
      SvREFCNT_dec (req->callback);
      req->callback = SvREFCNT_inc (POPs);
    }

  ++nreqs;

  X_LOCK (reqlock);
  ++nready;
  reqq_push (&req_queue, req);
  X_COND_SIGNAL (reqwait);
  X_UNLOCK (reqlock);

  maybe_start_thread ();

  if (wait_callback)
    {
      dSP;
      PUSHMARK (SP);
      PUTBACK;
      call_sv (wait_callback, G_DISCARD);
      SvREFCNT_dec (wait_callback);
    }
}

static void end_thread (void)
{
  aio_req req;

  Newz (0, req, 1, aio_cb);

  req->type = REQ_QUIT;
  req->pri  = PRI_MAX + PRI_BIAS;

  X_LOCK (reqlock);
  reqq_push (&req_queue, req);
  X_COND_SIGNAL (reqwait);
  X_UNLOCK (reqlock);

  X_LOCK (wrklock);
  --started;
  X_UNLOCK (wrklock);
}

static void set_max_idle (int nthreads)
{
  if (WORDACCESS_UNSAFE) X_LOCK   (reqlock);
  max_idle = nthreads <= 0 ? 1 : nthreads;
  if (WORDACCESS_UNSAFE) X_UNLOCK (reqlock);
}

static void min_parallel (int nthreads)
{
  if (wanted < nthreads)
    wanted = nthreads;
}

static void max_parallel (int nthreads)
{
  if (wanted > nthreads)
    wanted = nthreads;

  while (started > wanted)
    end_thread ();
}

static void poll_wait ()
{
  fd_set rfd;

  while (nreqs)
    {
      int size;
      if (WORDACCESS_UNSAFE) X_LOCK   (reslock);
      size = res_queue.size;
      if (WORDACCESS_UNSAFE) X_UNLOCK (reslock);

      if (size)
        return;

      maybe_start_thread ();

      FD_ZERO (&rfd);
      FD_SET (respipe [0], &rfd);

      PerlSock_select (respipe [0] + 1, &rfd, 0, 0, 0);
    }
}

static int poll_cb ()
{
  dSP;
  int count = 0;
  int maxreqs = max_poll_reqs;
  int do_croak = 0;
  struct timeval tv_start, tv_now;
  aio_req req;

  if (max_poll_time)
    gettimeofday (&tv_start, 0);

  for (;;)
    {
      for (;;)
        {
          maybe_start_thread ();

          X_LOCK (reslock);
          req = reqq_shift (&res_queue);

          if (req)
            {
              --npending;

              if (!res_queue.size)
                {
                  /* read any signals sent by the worker threads */
                  char buf [4];
                  while (respipe_read (respipe [0], buf, 4) == 4)
                    ;
                }
            }

          X_UNLOCK (reslock);

          if (!req)
            break;

          --nreqs;

          if (!req_invoke (req))
            {
              req_free (req);
              croak (0);
            }

          count++;

          req_free (req);

          if (maxreqs && !--maxreqs)
            break;

          if (max_poll_time)
            {
              gettimeofday (&tv_now, 0);

              if (tvdiff (&tv_start, &tv_now) >= max_poll_time)
                break;
            }
        }

      if (nreqs <= max_outstanding)
        break;

      poll_wait ();

      ++maxreqs;
    }

  return count;
}

/*****************************************************************************/

X_THREAD_PROC (bdb_proc)
{
  aio_req req;
  struct timespec ts;
  worker *self = (worker *)thr_arg;

  /* try to distribute timeouts somewhat evenly */
  ts.tv_nsec = ((unsigned long)self & 1023UL) * (1000000000UL / 1024UL);

  for (;;)
    {
      ts.tv_sec  = time (0) + IDLE_TIMEOUT;

      X_LOCK (reqlock);

      for (;;)
        {
          self->req = req = reqq_shift (&req_queue);

          if (req)
            break;

          ++idle;

          if (X_COND_TIMEDWAIT (reqwait, reqlock, ts)
              == ETIMEDOUT)
            {
              if (idle > max_idle)
                {
                  --idle;
                  X_UNLOCK (reqlock);
                  X_LOCK (wrklock);
                  --started;
                  X_UNLOCK (wrklock);
                  goto quit;
                }

              /* we are allowed to idle, so do so without any timeout */
              X_COND_WAIT (reqwait, reqlock);
              ts.tv_sec  = time (0) + IDLE_TIMEOUT;
            }

          --idle;
        }

      --nready;

      X_UNLOCK (reqlock);
     
      switch (req->type)
        {
          case REQ_QUIT:
            goto quit;

          case REQ_ENV_OPEN:
            req->result = req->env->open (req->env, req->buf1, req->uint1, req->int1);
            break;

          case REQ_ENV_CLOSE:
            req->result = req->env->close (req->env, req->uint1);
            break;

          case REQ_ENV_TXN_CHECKPOINT:
            req->result = req->env->txn_checkpoint (req->env, req->uint1, req->int1, req->uint2);
            break;

          case REQ_ENV_LOCK_DETECT:
            req->result = req->env->lock_detect (req->env, req->uint1, req->uint2, &req->int1);
            break;

          case REQ_ENV_MEMP_SYNC:
            req->result = req->env->memp_sync (req->env, 0);
            break;

          case REQ_ENV_MEMP_TRICKLE:
            req->result = req->env->memp_trickle (req->env, req->int1, &req->int2);
            break;

          case REQ_DB_OPEN:
            req->result = req->db->open (req->db, req->txn, req->buf1, req->buf2, req->int1, req->uint1, req->int2);
            break;

          case REQ_DB_CLOSE:
            req->result = req->db->close (req->db, req->uint1);
            break;

          case REQ_DB_COMPACT:
            req->result = req->db->compact (req->db, req->txn, &req->dbt1, &req->dbt2, 0, req->uint1, 0);
            break;

          case REQ_DB_SYNC:
            req->result = req->db->sync (req->db, req->uint1);
            break;

          case REQ_DB_PUT:
            req->result = req->db->put (req->db, req->txn, &req->dbt1, &req->dbt2, req->uint1);
            break;

          case REQ_DB_GET:
            req->result = req->db->get (req->db, req->txn, &req->dbt1, &req->dbt3, req->uint1);
            break;

          case REQ_DB_PGET:
            req->result = req->db->pget (req->db, req->txn, &req->dbt1, &req->dbt2, &req->dbt3, req->uint1);
            break;

          case REQ_DB_DEL:
            req->result = req->db->del (req->db, req->txn, &req->dbt1, req->uint1);
            break;

          case REQ_DB_KEY_RANGE:
            req->result = req->db->key_range (req->db, req->txn, &req->dbt1, &req->key_range, req->uint1);
            break;

          case REQ_TXN_COMMIT:
            req->result = req->txn->commit (req->txn, req->uint1);
            break;

          case REQ_TXN_ABORT:
            req->result = req->txn->abort (req->txn);
            break;

          case REQ_C_CLOSE:
            req->result = req->dbc->c_close (req->dbc);
            break;

          case REQ_C_COUNT:
            {
              db_recno_t recno;
              req->result = req->dbc->c_count (req->dbc, &recno, req->uint1);
              req->uv1 = recno;
            }
            break;

          case REQ_C_PUT:
            req->result = req->dbc->c_put (req->dbc, &req->dbt1, &req->dbt2, req->uint1);
            break;

          case REQ_C_GET:
            req->result = req->dbc->c_get (req->dbc, &req->dbt1, &req->dbt3, req->uint1);
            break;

          case REQ_C_PGET:
            req->result = req->dbc->c_pget (req->dbc, &req->dbt1, &req->dbt2, &req->dbt3, req->uint1);
            break;

          case REQ_C_DEL:
            req->result = req->dbc->c_del (req->dbc, req->uint1);
            break;

          case REQ_SEQ_OPEN:
            req->result = req->seq->open (req->seq, req->txn, &req->dbt1, req->uint1);
            break;

          case REQ_SEQ_CLOSE:
            req->result = req->seq->close (req->seq, req->uint1);
            break;

          case REQ_SEQ_GET:
            req->result = req->seq->get (req->seq, req->txn, req->int1, &req->seq_t, req->uint1);
            break;

          case REQ_SEQ_REMOVE:
            req->result = req->seq->remove (req->seq, req->txn, req->uint1);
            break;

          default:
            req->result = ENOSYS;
            break;
        }

      X_LOCK (reslock);

      ++npending;

      if (!reqq_push (&res_queue, req))
        /* write a dummy byte to the pipe so fh becomes ready */
        respipe_write (respipe_osf [1], (const void *)&respipe_osf, 1);

      self->req = 0;
      worker_clear (self);

      X_UNLOCK (reslock);
    }

quit:
  X_LOCK (wrklock);
  worker_free (self);
  X_UNLOCK (wrklock);

  return 0;
}

/*****************************************************************************/

static void atfork_prepare (void)
{
  X_LOCK (wrklock);
  X_LOCK (reqlock);
  X_LOCK (reslock);
}

static void atfork_parent (void)
{
  X_UNLOCK (reslock);
  X_UNLOCK (reqlock);
  X_UNLOCK (wrklock);
}

static void atfork_child (void)
{
  aio_req prv;

  while (prv = reqq_shift (&req_queue))
    req_free (prv);

  while (prv = reqq_shift (&res_queue))
    req_free (prv);

  while (wrk_first.next != &wrk_first)
    {
      worker *wrk = wrk_first.next;

      if (wrk->req)
        req_free (wrk->req);

      worker_clear (wrk);
      worker_free (wrk);
    }

  started  = 0;
  idle     = 0;
  nreqs    = 0;
  nready   = 0;
  npending = 0;

  respipe_close (respipe [0]);
  respipe_close (respipe [1]);

  create_pipe (respipe);

  atfork_parent ();
}

#define dREQ(reqtype)						\
  aio_req req;							\
  int req_pri = next_pri;					\
  next_pri = DEFAULT_PRI + PRI_BIAS;				\
								\
  if (SvOK (callback) && !SvROK (callback))			\
    croak ("callback must be undef or of reference type");	\
								\
  Newz (0, req, 1, aio_cb);	        			\
  if (!req)							\
    croak ("out of memory during aio_req allocation");		\
								\
  req->callback = newSVsv (callback);				\
  req->type = (reqtype); 					\
  req->pri = req_pri

#define REQ_SEND						\
  req_send (req)

#define SvPTR(var, arg, type, class, nullok)                    		\
  if (!SvOK (arg))								\
    {										\
      if (!nullok)								\
        croak (# var " must be a " # class " object, not undef");		\
										\
      (var) = 0;								\
    }										\
  else if (sv_derived_from ((arg), # class))                    		\
    {                                                           		\
      IV tmp = SvIV ((SV*) SvRV (arg));                         		\
      (var) = INT2PTR (type, tmp);                              		\
      if (!var)									\
        croak (# var " is not a valid " # class " object anymore");		\
    }                                                           		\
  else                                                          		\
    croak (# var " is not of type " # class);					\
										\

static void
ptr_nuke (SV *sv)
{
  assert (SvROK (sv));
  sv_setiv (SvRV (sv), 0);
}

MODULE = BDB                PACKAGE = BDB

PROTOTYPES: ENABLE

BOOT:
{
	HV *stash = gv_stashpv ("BDB", 1);

        static const struct {
          const char *name;
          IV iv;
        } *civ, const_iv[] = {
#define const_iv(name) { # name, (IV)DB_ ## name },
          const_iv (RPCCLIENT)
          const_iv (INIT_CDB)
          const_iv (INIT_LOCK)
          const_iv (INIT_LOG)
          const_iv (INIT_MPOOL)
          const_iv (INIT_REP)
          const_iv (INIT_TXN)
          const_iv (RECOVER)
          const_iv (INIT_TXN)
          const_iv (RECOVER_FATAL)
          const_iv (CREATE)
          const_iv (USE_ENVIRON)
          const_iv (USE_ENVIRON_ROOT)
          const_iv (LOCKDOWN)
          const_iv (PRIVATE)
          const_iv (REGISTER)
          const_iv (SYSTEM_MEM)
          const_iv (AUTO_COMMIT)
          const_iv (CDB_ALLDB)
          const_iv (DIRECT_DB)
          const_iv (DIRECT_LOG)
          const_iv (DSYNC_DB)
          const_iv (DSYNC_LOG)
          const_iv (LOG_AUTOREMOVE)
          const_iv (LOG_INMEMORY)
          const_iv (NOLOCKING)
          const_iv (NOMMAP)
          const_iv (NOPANIC)
          const_iv (OVERWRITE)
          const_iv (PANIC_ENVIRONMENT)
          const_iv (REGION_INIT)
          const_iv (TIME_NOTGRANTED)
          const_iv (TXN_NOSYNC)
          const_iv (TXN_WRITE_NOSYNC)
          const_iv (WRITECURSOR)
          const_iv (YIELDCPU)
          const_iv (ENCRYPT_AES)
          const_iv (XA_CREATE)
          const_iv (BTREE)
          const_iv (HASH)
          const_iv (QUEUE)
          const_iv (RECNO)
          const_iv (UNKNOWN)
          const_iv (EXCL)
          const_iv (READ_COMMITTED)
          const_iv (READ_UNCOMMITTED)
          const_iv (TRUNCATE)
          const_iv (NOSYNC)
          const_iv (CHKSUM)
          const_iv (ENCRYPT)
          const_iv (TXN_NOT_DURABLE)
          const_iv (DUP)
          const_iv (DUPSORT)
          const_iv (RECNUM)
          const_iv (RENUMBER)
          const_iv (REVSPLITOFF)
          const_iv (INORDER)
          const_iv (CONSUME)
          const_iv (CONSUME_WAIT)
          const_iv (GET_BOTH)
          const_iv (GET_BOTH_RANGE)
          //const_iv (SET_RECNO)
          //const_iv (MULTIPLE)
          const_iv (SNAPSHOT)
          const_iv (JOIN_ITEM)
          const_iv (RMW)

          const_iv (NOTFOUND)
          const_iv (KEYEMPTY)
          const_iv (LOCK_DEADLOCK)
          const_iv (LOCK_NOTGRANTED)
          const_iv (RUNRECOVERY)
          const_iv (OLD_VERSION)
          const_iv (REP_HANDLE_DEAD)
          const_iv (REP_LOCKOUT)
          const_iv (SECONDARY_BAD)

          const_iv (FREE_SPACE)
          const_iv (FREELIST_ONLY)

          const_iv (APPEND)
          const_iv (NODUPDATA)
          const_iv (NOOVERWRITE)

          const_iv (TXN_NOWAIT)
          const_iv (TXN_SYNC)

          const_iv (SET_LOCK_TIMEOUT)
          const_iv (SET_TXN_TIMEOUT)

          const_iv (JOIN_ITEM)
          const_iv (FIRST)
          const_iv (NEXT)
          const_iv (NEXT_DUP)
          const_iv (NEXT_NODUP)
          const_iv (PREV)
          const_iv (PREV_NODUP)
          const_iv (SET)
          const_iv (SET_RANGE)
          const_iv (LAST)
          const_iv (BEFORE)
          const_iv (AFTER)
          const_iv (CURRENT)
          const_iv (KEYFIRST)
          const_iv (KEYLAST)
          const_iv (NODUPDATA)

          const_iv (FORCE)

          const_iv (LOCK_DEFAULT)
          const_iv (LOCK_EXPIRE)
          const_iv (LOCK_MAXLOCKS)
          const_iv (LOCK_MAXWRITE)
          const_iv (LOCK_MINLOCKS)
          const_iv (LOCK_MINWRITE)
          const_iv (LOCK_OLDEST)
          const_iv (LOCK_RANDOM)
          const_iv (LOCK_YOUNGEST)

          const_iv (SEQ_DEC)
          const_iv (SEQ_INC)
          const_iv (SEQ_WRAP)

          const_iv (BUFFER_SMALL)
          const_iv (DONOTINDEX)
          const_iv (KEYEMPTY	)
          const_iv (KEYEXIST	)
          const_iv (LOCK_DEADLOCK)
          const_iv (LOCK_NOTGRANTED)
          const_iv (LOG_BUFFER_FULL)
          const_iv (NOSERVER)
          const_iv (NOSERVER_HOME)
          const_iv (NOSERVER_ID)
          const_iv (NOTFOUND)
          const_iv (OLD_VERSION)
          const_iv (PAGE_NOTFOUND)
          const_iv (REP_DUPMASTER)
          const_iv (REP_HANDLE_DEAD)
          const_iv (REP_HOLDELECTION)
          const_iv (REP_IGNORE)
          const_iv (REP_ISPERM)
          const_iv (REP_JOIN_FAILURE)
          const_iv (REP_LOCKOUT)
          const_iv (REP_NEWMASTER)
          const_iv (REP_NEWSITE)
          const_iv (REP_NOTPERM)
          const_iv (REP_UNAVAIL)
          const_iv (RUNRECOVERY)
          const_iv (SECONDARY_BAD)
          const_iv (VERIFY_BAD)
          const_iv (VERSION_MISMATCH)

          const_iv (VERB_DEADLOCK)
          const_iv (VERB_RECOVERY)
          const_iv (VERB_REGISTER)
          const_iv (VERB_REPLICATION)
          const_iv (VERB_WAITSFOR)

          const_iv (VERSION_MAJOR)
          const_iv (VERSION_MINOR)
          const_iv (VERSION_PATCH)
#if DB_VERSION_MINOR >= 5
          const_iv (MULTIVERSION)
          const_iv (TXN_SNAPSHOT)
#endif
        };

        for (civ = const_iv + sizeof (const_iv) / sizeof (const_iv [0]); civ-- > const_iv; )
          newCONSTSUB (stash, (char *)civ->name, newSViv (civ->iv));

        newCONSTSUB (stash, "DB_VERSION", newSVnv (DB_VERSION_MAJOR + DB_VERSION_MINOR * .1));
        newCONSTSUB (stash, "DB_VERSION_STRING", newSVpv (DB_VERSION_STRING, 0));

        create_pipe (respipe);

        X_THREAD_ATFORK (atfork_prepare, atfork_parent, atfork_child);
#ifdef _WIN32
        X_MUTEX_CHECK (wrklock);
        X_MUTEX_CHECK (reslock);
        X_MUTEX_CHECK (reqlock);

        X_COND_CHECK  (reqwait);
#endif
}

void
max_poll_reqs (int nreqs)
	PROTOTYPE: $
        CODE:
        max_poll_reqs = nreqs;

void
max_poll_time (double nseconds)
	PROTOTYPE: $
        CODE:
        max_poll_time = nseconds * AIO_TICKS;

void
min_parallel (int nthreads)
	PROTOTYPE: $

void
max_parallel (int nthreads)
	PROTOTYPE: $

void
max_idle (int nthreads)
	PROTOTYPE: $
        CODE:
        set_max_idle (nthreads);

int
max_outstanding (int maxreqs)
	PROTOTYPE: $
        CODE:
        RETVAL = max_outstanding;
        max_outstanding = maxreqs;
	OUTPUT:
        RETVAL

int
dbreq_pri (int pri = 0)
	PROTOTYPE: ;$
	CODE:
	RETVAL = next_pri - PRI_BIAS;
	if (items > 0)
	  {
	    if (pri < PRI_MIN) pri = PRI_MIN;
	    if (pri > PRI_MAX) pri = PRI_MAX;
	    next_pri = pri + PRI_BIAS;
	  }
	OUTPUT:
	RETVAL

void
dbreq_nice (int nice = 0)
	CODE:
	nice = next_pri - nice;
	if (nice < PRI_MIN) nice = PRI_MIN;
	if (nice > PRI_MAX) nice = PRI_MAX;
	next_pri = nice + PRI_BIAS;

void
flush ()
	PROTOTYPE:
	CODE:
        while (nreqs)
          {
            poll_wait ();
            poll_cb ();
          }

int
poll ()
	PROTOTYPE:
	CODE:
        poll_wait ();
        RETVAL = poll_cb ();
	OUTPUT:
	RETVAL

int
poll_fileno ()
	PROTOTYPE:
	CODE:
        RETVAL = respipe [0];
	OUTPUT:
	RETVAL

int
poll_cb (...)
	PROTOTYPE:
	CODE:
        RETVAL = poll_cb ();
	OUTPUT:
	RETVAL

void
poll_wait ()
	PROTOTYPE:
	CODE:
        poll_wait ();

int
nreqs ()
	PROTOTYPE:
	CODE:
        RETVAL = nreqs;
	OUTPUT:
	RETVAL

int
nready ()
	PROTOTYPE:
	CODE:
        RETVAL = get_nready ();
	OUTPUT:
	RETVAL

int
npending ()
	PROTOTYPE:
	CODE:
        RETVAL = get_npending ();
	OUTPUT:
	RETVAL

int
nthreads ()
	PROTOTYPE:
	CODE:
        if (WORDACCESS_UNSAFE) X_LOCK   (wrklock);
        RETVAL = started;
        if (WORDACCESS_UNSAFE) X_UNLOCK (wrklock);
	OUTPUT:
	RETVAL

void
set_sync_prepare (SV *cb)
	PROTOTYPE: &
	CODE:
        SvREFCNT_dec (prepare_cb);
        prepare_cb = newSVsv (cb);

char *
strerror (int errorno = errno)
	PROTOTYPE: ;$
        CODE:
        RETVAL = db_strerror (errorno);
	OUTPUT:
        RETVAL

DB_ENV *
db_env_create (U32 env_flags = 0)
	CODE:
{
        errno = db_env_create (&RETVAL, env_flags);
        if (errno)
          croak ("db_env_create: %s", db_strerror (errno));

        if (0)
          {
            RETVAL->set_errcall (RETVAL, debug_errcall);
            RETVAL->set_msgcall (RETVAL, debug_msgcall);
          }
}
	OUTPUT:
	RETVAL

void
db_env_open (DB_ENV *env, octetstring db_home, U32 open_flags, int mode, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_ENV_OPEN);

  	env->set_thread_count (env, wanted + 2);

        req->env   = env;
        req->uint1 = open_flags | DB_THREAD;
        req->int1  = mode;
        req->buf1  = strdup_ornull (db_home);
        REQ_SEND;
}

void
db_env_close (DB_ENV *env, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
	dREQ (REQ_ENV_CLOSE);
        req->env   = env;
        req->uint1 = flags;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_env_txn_checkpoint (DB_ENV *env, U32 kbyte = 0, U32 min = 0, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_ENV_TXN_CHECKPOINT);
        req->env   = env;
        req->uint1 = kbyte;
        req->int1  = min;
        req->uint2 = flags;
        REQ_SEND;
}

void
db_env_lock_detect (DB_ENV *env, U32 flags = 0, U32 atype = DB_LOCK_DEFAULT, SV *dummy = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_ENV_LOCK_DETECT);
        req->env   = env;
        req->uint1 = flags;
        req->uint2 = atype;
        REQ_SEND;
}

void
db_env_memp_sync (DB_ENV *env, SV *dummy = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_ENV_MEMP_SYNC);
        req->env  = env;
        REQ_SEND;
}

void
db_env_memp_trickle (DB_ENV *env, int percent, SV *dummy = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_ENV_MEMP_TRICKLE);
        req->env  = env;
        req->int1 = percent;
        REQ_SEND;
}


DB *
db_create (DB_ENV *env = 0, U32 flags = 0)
	CODE:
{
        errno = db_create (&RETVAL, env, flags);
        if (errno)
          croak ("db_create: %s", db_strerror (errno));

        if (RETVAL)
          RETVAL->app_private = (void *)newSVsv (ST (0));
}
	OUTPUT:
	RETVAL

void
db_open (DB *db, DB_TXN_ornull *txnid, octetstring file, octetstring database, int type, U32 flags, int mode, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_OPEN);
        req->db    = db;
        req->txn   = txnid;
        req->buf1  = strdup_ornull (file);
        req->buf2  = strdup_ornull (database);
        req->int1  = type;
        req->uint1 = flags | DB_THREAD;
        req->int2  = mode;
        REQ_SEND;
}

void
db_close (DB *db, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_CLOSE);
        req->db    = db;
        req->uint1 = flags;
        req->sv1   = (SV *)db->app_private;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_compact (DB *db, DB_TXN_ornull *txn = 0, SV *start = 0, SV *stop = 0, SV *unused1 = 0, U32 flags = DB_FREE_SPACE, SV *unused2 = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_COMPACT);
        req->db    = db;
        req->txn   = txn;
        sv_to_dbt (&req->dbt1, start);
        sv_to_dbt (&req->dbt2, stop);
        req->uint1 = flags;
        REQ_SEND;
}

void
db_sync (DB *db, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_SYNC);
        req->db    = db;
        req->uint1 = flags;
        REQ_SEND;
}

void
db_key_range (DB *db, DB_TXN_ornull *txn, SV *key, SV *key_range, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_KEY_RANGE);
        req->db    = db;
        req->txn   = txn;
        sv_to_dbt (&req->dbt1, key);
        req->uint1 = flags;
        req->sv1   = SvREFCNT_inc (key_range); SvREADONLY_on (key_range);
        REQ_SEND;
}

void
db_put (DB *db, DB_TXN_ornull *txn, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_PUT);
        req->db    = db;
        req->txn   = txn;
        sv_to_dbt (&req->dbt1, key);
        sv_to_dbt (&req->dbt2, data);
        req->uint1 = flags;
        REQ_SEND;
}

void
db_get (DB *db, DB_TXN_ornull *txn, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_GET);
        req->db    = db;
        req->txn   = txn;
        req->uint1 = flags;
        sv_to_dbt (&req->dbt1, key);
        req->dbt3.flags = DB_DBT_MALLOC;
        req->sv3 = SvREFCNT_inc (data); SvREADONLY_on (data);
        REQ_SEND;
}

void
db_pget (DB *db, DB_TXN_ornull *txn, SV *key, SV *pkey, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_PGET);
        req->db    = db;
        req->txn   = txn;
        req->uint1 = flags;
        sv_to_dbt (&req->dbt1, key);
        sv_to_dbt (&req->dbt2, pkey);
        req->dbt3.flags = DB_DBT_MALLOC;
        req->sv3 = SvREFCNT_inc (data); SvREADONLY_on (data);
        REQ_SEND;
}

void
db_del (DB *db, DB_TXN_ornull *txn, SV *key, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_DB_DEL);
        req->db    = db;
        req->txn   = txn;
        req->uint1 = flags;
        sv_to_dbt (&req->dbt1, key);
        REQ_SEND;
}

void
db_txn_commit (DB_TXN *txn, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_TXN_COMMIT);
        req->txn   = txn;
        req->uint1 = flags;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_txn_abort (DB_TXN *txn, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_TXN_ABORT);
        req->txn   = txn;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_c_close (DBC *dbc, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_CLOSE);
        req->dbc = dbc;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_c_count (DBC *dbc, SV *count, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_COUNT);
        req->dbc = dbc;
        req->sv1 = SvREFCNT_inc (count);
        REQ_SEND;
}

void
db_c_put (DBC *dbc, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_PUT);
        req->dbc   = dbc;
        sv_to_dbt (&req->dbt1, key);
        sv_to_dbt (&req->dbt2, data);
        req->uint1 = flags;
        REQ_SEND;
}

void
db_c_get (DBC *dbc, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_GET);
        req->dbc   = dbc;
        req->uint1 = flags;
        if ((flags & DB_SET) == DB_SET
            || (flags & DB_SET_RANGE) == DB_SET_RANGE)
          sv_to_dbt (&req->dbt1, key);
        else
          req->dbt1.flags = DB_DBT_MALLOC;

        req->sv1 = SvREFCNT_inc (key); SvREADONLY_on (key);

        if ((flags & DB_GET_BOTH) == DB_GET_BOTH
            || (flags & DB_GET_BOTH_RANGE) == DB_GET_BOTH_RANGE)
          sv_to_dbt (&req->dbt3, data);
        else
          req->dbt3.flags = DB_DBT_MALLOC;

        req->sv3 = SvREFCNT_inc (data); SvREADONLY_on (data);
        REQ_SEND;
}

void
db_c_pget (DBC *dbc, SV *key, SV *pkey, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_PGET);
        req->dbc   = dbc;
        req->uint1 = flags;
        if ((flags & DB_SET) == DB_SET
            || (flags & DB_SET_RANGE) == DB_SET_RANGE)
          sv_to_dbt (&req->dbt1, key);
        else
          req->dbt1.flags = DB_DBT_MALLOC;

        req->sv1 = SvREFCNT_inc (key); SvREADONLY_on (key);

        req->dbt2.flags = DB_DBT_MALLOC;
        req->sv2 = SvREFCNT_inc (pkey); SvREADONLY_on (pkey);

        if ((flags & DB_GET_BOTH) == DB_GET_BOTH
            || (flags & DB_GET_BOTH_RANGE) == DB_GET_BOTH_RANGE)
          sv_to_dbt (&req->dbt3, data);
        else
          req->dbt3.flags = DB_DBT_MALLOC;

        req->sv3 = SvREFCNT_inc (data); SvREADONLY_on (data);
        REQ_SEND;
}

void
db_c_del (DBC *dbc, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_C_DEL);
        req->dbc   = dbc;
        req->uint1 = flags;
        REQ_SEND;
}


void
db_sequence_open (DB_SEQUENCE *seq, DB_TXN_ornull *txnid, SV *key, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_SEQ_OPEN);
        req->seq   = seq;
        req->txn   = txnid;
        req->uint1 = flags | DB_THREAD;
        sv_to_dbt (&req->dbt1, key);
        REQ_SEND;
}

void
db_sequence_close (DB_SEQUENCE *seq, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_SEQ_CLOSE);
        req->seq   = seq;
        req->uint1 = flags;
        REQ_SEND;
        ptr_nuke (ST (0));
}

void
db_sequence_get (DB_SEQUENCE *seq, DB_TXN_ornull *txnid, int delta, SV *seq_value, U32 flags = DB_TXN_NOSYNC, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_SEQ_GET);
        req->seq   = seq;
        req->txn   = txnid;
        req->int1  = delta;
        req->uint1 = flags;
        req->sv1   = SvREFCNT_inc (seq_value); SvREADONLY_on (seq_value);
        REQ_SEND;
}

void
db_sequence_remove (DB_SEQUENCE *seq, DB_TXN_ornull *txnid = 0, U32 flags = 0, SV *callback = &PL_sv_undef)
	CODE:
{
        dREQ (REQ_SEQ_REMOVE);
        req->seq   = seq;
        req->txn   = txnid;
        req->uint1 = flags;
        REQ_SEND;
}


MODULE = BDB		PACKAGE = BDB::Env

void
DESTROY (DB_ENV_ornull *env)
	CODE:
        if (env)
          env->close (env, 0);

int set_data_dir (DB_ENV *env, const char *dir)
	CODE:
        RETVAL = env->set_data_dir (env, dir);
	OUTPUT:
        RETVAL

int set_tmp_dir (DB_ENV *env, const char *dir)
	CODE:
        RETVAL = env->set_tmp_dir (env, dir);
	OUTPUT:
        RETVAL

int set_lg_dir (DB_ENV *env, const char *dir)
	CODE:
        RETVAL = env->set_lg_dir (env, dir);
	OUTPUT:
        RETVAL

int set_shm_key (DB_ENV *env, long shm_key)
	CODE:
        RETVAL = env->set_shm_key (env, shm_key);
	OUTPUT:
        RETVAL

int set_cachesize (DB_ENV *env, U32 gbytes, U32 bytes, int ncache = 0)
	CODE:
        RETVAL = env->set_cachesize (env, gbytes, bytes, ncache);
	OUTPUT:
        RETVAL

int set_flags (DB_ENV *env, U32 flags, int onoff)
	CODE:
        RETVAL = env->set_flags (env, flags, onoff);
	OUTPUT:
        RETVAL

void set_errfile (DB_ENV *env, FILE *errfile)
	CODE:
        env->set_errfile (env, errfile);

void set_msgfile (DB_ENV *env, FILE *msgfile)
	CODE:
        env->set_msgfile (env, msgfile);

int set_verbose (DB_ENV *env, U32 which, int onoff = 1)
	CODE:
        RETVAL = env->set_verbose (env, which, onoff);
	OUTPUT:
        RETVAL

int set_encrypt (DB_ENV *env, const char *password, U32 flags = 0)
	CODE:
        RETVAL = env->set_encrypt (env, password, flags);
	OUTPUT:
        RETVAL

int set_timeout (DB_ENV *env, NV timeout, U32 flags)
	CODE:
        RETVAL = env->set_timeout (env, timeout * 1000000, flags);
	OUTPUT:
        RETVAL

int set_mp_max_openfd (DB_ENV *env, int maxopenfd);
	CODE:
        RETVAL = env->set_mp_max_openfd (env, maxopenfd);
	OUTPUT:
        RETVAL

int set_mp_max_write (DB_ENV *env, int maxwrite, int maxwrite_sleep);
	CODE:
        RETVAL = env->set_mp_max_write (env, maxwrite, maxwrite_sleep);
	OUTPUT:
        RETVAL

int set_mp_mmapsize (DB_ENV *env, int mmapsize_mb)
	CODE:
        RETVAL = env->set_mp_mmapsize (env, ((size_t)mmapsize_mb) << 20);
	OUTPUT:
        RETVAL

int set_lk_detect (DB_ENV *env, U32 detect = DB_LOCK_DEFAULT)
	CODE:
        RETVAL = env->set_lk_detect (env, detect);
	OUTPUT:
        RETVAL

int set_lk_max_lockers (DB_ENV *env, U32 max)
	CODE:
        RETVAL = env->set_lk_max_lockers (env, max);
	OUTPUT:
        RETVAL

int set_lk_max_locks (DB_ENV *env, U32 max)
	CODE:
        RETVAL = env->set_lk_max_locks (env, max);
	OUTPUT:
        RETVAL

int set_lk_max_objects (DB_ENV *env, U32 max)
	CODE:
        RETVAL = env->set_lk_max_objects (env, max);
	OUTPUT:
        RETVAL

int set_lg_bsize (DB_ENV *env, U32 max)
	CODE:
        RETVAL = env->set_lg_bsize (env, max);
	OUTPUT:
        RETVAL

int set_lg_max (DB_ENV *env, U32 max)
	CODE:
        RETVAL = env->set_lg_max (env, max);
	OUTPUT:
        RETVAL

DB_TXN *
txn_begin (DB_ENV *env, DB_TXN_ornull *parent = 0, U32 flags = 0)
	CODE:
        errno = env->txn_begin (env, parent, &RETVAL, flags);
        if (errno)
          croak ("DB_ENV->txn_begin: %s", db_strerror (errno));
        OUTPUT:
        RETVAL

MODULE = BDB		PACKAGE = BDB::Db

void
DESTROY (DB_ornull *db)
	CODE:
        if (db)
          {
            SV *env = (SV *)db->app_private;
            db->close (db, 0);
            SvREFCNT_dec (env);
          }

int set_cachesize (DB *db, U32 gbytes, U32 bytes, int ncache = 0)
	CODE:
        RETVAL = db->set_cachesize (db, gbytes, bytes, ncache);
	OUTPUT:
        RETVAL

int set_flags (DB *db, U32 flags);
	CODE:
        RETVAL = db->set_flags (db, flags);
	OUTPUT:
        RETVAL

int set_encrypt (DB *db, const char *password, U32 flags)
	CODE:
        RETVAL = db->set_encrypt (db, password, flags);
	OUTPUT:
        RETVAL

int set_lorder (DB *db, int lorder)
	CODE:
        RETVAL = db->set_lorder (db, lorder);
	OUTPUT:
        RETVAL

int set_bt_minkey (DB *db, U32 minkey)
	CODE:
        RETVAL = db->set_bt_minkey (db, minkey);
	OUTPUT:
        RETVAL

int set_re_delim(DB *db, int delim);
	CODE:
        RETVAL = db->set_re_delim (db, delim);
	OUTPUT:
        RETVAL

int set_re_pad (DB *db, int re_pad)
	CODE:
        RETVAL = db->set_re_pad (db, re_pad);
	OUTPUT:
        RETVAL

int set_re_source (DB *db, char *source)
	CODE:
        RETVAL = db->set_re_source (db, source);
	OUTPUT:
        RETVAL

int set_re_len (DB *db, U32 re_len)
	CODE:
        RETVAL = db->set_re_len (db, re_len);
	OUTPUT:
        RETVAL

int set_h_ffactor (DB *db, U32 h_ffactor)
	CODE:
        RETVAL = db->set_h_ffactor (db, h_ffactor);
	OUTPUT:
        RETVAL

int set_h_nelem (DB *db, U32 h_nelem)
	CODE:
        RETVAL = db->set_h_nelem (db, h_nelem);
	OUTPUT:
        RETVAL

int set_q_extentsize (DB *db, U32 extentsize)
	CODE:
        RETVAL = db->set_q_extentsize (db, extentsize);
	OUTPUT:
        RETVAL

DBC *
cursor (DB *db, DB_TXN_ornull *txn = 0, U32 flags = 0)
	CODE:
        errno = db->cursor (db, txn, &RETVAL, flags);
        if (errno)
          croak ("DB->cursor: %s", db_strerror (errno));
        OUTPUT:
        RETVAL

DB_SEQUENCE *
sequence (DB *db, U32 flags = 0)
	CODE:
{
        errno = db_sequence_create (&RETVAL, db, flags);
        if (errno)
          croak ("db_sequence_create: %s", db_strerror (errno));
}
	OUTPUT:
	RETVAL


MODULE = BDB		PACKAGE = BDB::Txn

void
DESTROY (DB_TXN_ornull *txn)
	CODE:
        if (txn)
          txn->abort (txn);

int set_timeout (DB_TXN *txn, NV timeout, U32 flags)
	CODE:
        RETVAL = txn->set_timeout (txn, timeout * 1000000, flags);
	OUTPUT:
        RETVAL


MODULE = BDB		PACKAGE = BDB::Cursor

void
DESTROY (DBC_ornull *dbc)
	CODE:
        if (dbc)
          dbc->c_close (dbc);

MODULE = BDB		PACKAGE = BDB::Sequence

void
DESTROY (DB_SEQUENCE_ornull *seq)
	CODE:
        if (seq)
          seq->close (seq, 0);

int initial_value (DB_SEQUENCE *seq, db_seq_t value)
	CODE:
        RETVAL = seq->initial_value (seq, value);
	OUTPUT:
        RETVAL

int set_cachesize (DB_SEQUENCE *seq, U32 size)
	CODE:
        RETVAL = seq->set_cachesize (seq, size);
	OUTPUT:
        RETVAL

int set_flags (DB_SEQUENCE *seq, U32 flags)
	CODE:
        RETVAL = seq->set_flags (seq, flags);
	OUTPUT:
        RETVAL

int set_range (DB_SEQUENCE *seq, db_seq_t min, db_seq_t max)
	CODE:
        RETVAL = seq->set_range (seq, min, max);
	OUTPUT:
        RETVAL

