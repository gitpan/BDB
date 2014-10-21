=head1 NAME

BDB - Asynchronous Berkeley DB access

=head1 SYNOPSIS

 use BDB;

 my $env = db_env_create;

 mkdir "bdtest", 0700;
 db_env_open
    $env,
    "bdtest",
    BDB::INIT_LOCK | BDB::INIT_LOG | BDB::INIT_MPOOL
    | BDB::INIT_TXN | BDB::RECOVER | BDB::USE_ENVIRON | BDB::CREATE,
    0600;

 $env->set_flags (BDB::AUTO_COMMIT | BDB::TXN_NOSYNC, 1);

 my $db = db_create $env;
 db_open $db, undef, "table", undef, BDB::BTREE, BDB::AUTO_COMMIT | BDB::CREATE
                                     | BDB::READ_UNCOMMITTED, 0600;
 db_put $db, undef, "key", "data", 0, sub {
    db_del $db, undef, "key";
 };
 db_sync $db;

 # when you also use Coro, management is easy:
 use Coro::BDB;

 # automatic result processing with AnyEvent:
 our $FH; open $FH, "<&=" . BDB::poll_fileno;
 our $WATCHER = AnyEvent->io (fh => $FH, poll => 'r', cb => \&BDB::poll_cb);

 # automatic result processing with EV:
 my $WATCHER = EV::io BDB::poll_fileno, EV::READ, \&BDB::poll_cb;

 # with Glib:
 add_watch Glib::IO BDB::poll_fileno,
           in => sub { BDB::poll_cb; 1 };

 # or simply flush manually
 BDB::flush;


=head1 DESCRIPTION

See the BerkeleyDB documentation (L<http://www.oracle.com/technology/documentation/berkeley-db/db/index.html>).
The BDB API is very similar to the C API (the translation has been very faithful).

See also the example sections in the document below and possibly the eg/
subdirectory of the BDB distribution. Last not least see the IO::AIO
documentation, as that module uses almost the same asynchronous request
model as this module.

I know this is woefully inadequate documentation. Send a patch!


=head1 REQUEST ANATOMY AND LIFETIME

Every request method creates a request. which is a C data structure not
directly visible to Perl.

During their existance, bdb requests travel through the following states,
in order:

=over 4

=item ready

Immediately after a request is created it is put into the ready state,
waiting for a thread to execute it.

=item execute

A thread has accepted the request for processing and is currently
executing it (e.g. blocking in read).

=item pending

The request has been executed and is waiting for result processing.

While request submission and execution is fully asynchronous, result
processing is not and relies on the perl interpreter calling C<poll_cb>
(or another function with the same effect).

=item result

The request results are processed synchronously by C<poll_cb>.

The C<poll_cb> function will process all outstanding aio requests by
calling their callbacks, freeing memory associated with them and managing
any groups they are contained in.

=item done

Request has reached the end of its lifetime and holds no resources anymore
(except possibly for the Perl object, but its connection to the actual
aio request is severed and calling its methods will either do nothing or
result in a runtime error).

=back

=cut

package BDB;

no warnings;
use strict 'vars';

use base 'Exporter';

BEGIN {
   our $VERSION = '1.44';

   our @BDB_REQ = qw(
      db_env_open db_env_close db_env_txn_checkpoint db_env_lock_detect
      db_env_memp_sync db_env_memp_trickle
      db_open db_close db_compact db_sync db_upgrade
      db_put db_get db_pget db_del db_key_range
      db_txn_commit db_txn_abort db_txn_finish
      db_c_close db_c_count db_c_put db_c_get db_c_pget db_c_del
      db_sequence_open db_sequence_close
      db_sequence_get db_sequence_remove
   );
   our @EXPORT = (@BDB_REQ, qw(dbreq_pri dbreq_nice db_env_create db_create));
   our @EXPORT_OK = qw(
      poll_fileno poll_cb poll_wait flush
      min_parallel max_parallel max_idle
      nreqs nready npending nthreads
      max_poll_time max_poll_reqs
   );

   require XSLoader;
   XSLoader::load ("BDB", $VERSION);
}

=head2 FILENAMES/DATABASE NAMES

The BDB expects "binary" filenames (octet strings) for pathnames on POSIX
systems, and "unicode" filenames (strings with characters potentially
>255) on Win32 (expecting a Unicode win32 build - win32 is a total mess).

=head2 BERKELEYDB FUNCTIONS

All of these are functions. The create functions simply return a new
object and never block. All the remaining functions take an optional
callback as last argument. If it is missing, then the function will be
executed synchronously. In both cases, C<$!> will reflect the return value
of the function.

BDB functions that cannot block (mostly functions that manipulate
settings) are method calls on the relevant objects, so the rule of thumb
is: if it's a method, it's not blocking, if it's a function, it takes a
callback as last argument.

In the following, C<$int> signifies an integer return value,
C<octetstring> is a "binary string" (i.e. a perl string with no character
indices >255), C<U32> is an unsigned 32 bit integer, C<int> is some
integer, C<NV> is a floating point value.

The C<SV *> types are generic perl scalars (for input and output of data
values), and the C<SV *callback> is the optional callback function to call
when the request is completed.

The various C<DB_ENV> etc. arguments are handles return by
C<db_env_create>, C<db_create>, C<txn_begin> and so on. If they have an
appended C<_ornull> this means they are optional and you can pass C<undef>
for them, resulting a NULL pointer on the C level.

=head3 BDB functions

Functions in the BDB namespace, exported by default:

   $env = db_env_create (U32 env_flags = 0)
      flags: RPCCLIENT

   db_env_open (DB_ENV *env, octetstring db_home, U32 open_flags, int mode, SV *callback = &PL_sv_undef)
      open_flags: INIT_CDB INIT_LOCK INIT_LOG INIT_MPOOL INIT_REP INIT_TXN RECOVER RECOVER_FATAL USE_ENVIRON USE_ENVIRON_ROOT CREATE LOCKDOWN PRIVATE REGISTER SYSTEM_MEM
   db_env_close (DB_ENV *env, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_env_txn_checkpoint (DB_ENV *env, U32 kbyte = 0, U32 min = 0, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: FORCE
   db_env_lock_detect (DB_ENV *env, U32 flags = 0, U32 atype = DB_LOCK_DEFAULT, SV *dummy = 0, SV *callback = &PL_sv_undef)
      atype: LOCK_DEFAULT LOCK_EXPIRE LOCK_MAXLOCKS LOCK_MAXWRITE LOCK_MINLOCKS LOCK_MINWRITE LOCK_OLDEST LOCK_RANDOM LOCK_YOUNGEST
   db_env_memp_sync (DB_ENV *env, SV *dummy = 0, SV *callback = &PL_sv_undef)
   db_env_memp_trickle (DB_ENV *env, int percent, SV *dummy = 0, SV *callback = &PL_sv_undef)

   $db = db_create (DB_ENV *env = 0, U32 flags = 0)
      flags: XA_CREATE

   db_open (DB *db, DB_TXN_ornull *txnid, octetstring file, octetstring database, int type, U32 flags, int mode, SV *callback = &PL_sv_undef)
      flags: AUTO_COMMIT CREATE EXCL MULTIVERSION NOMMAP RDONLY READ_UNCOMMITTED THREAD TRUNCATE
   db_close (DB *db, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: DB_NOSYNC
   db_upgrade (DB *db, octetstring file, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_compact (DB *db, DB_TXN_ornull *txn = 0, SV *start = 0, SV *stop = 0, SV *unused1 = 0, U32 flags = DB_FREE_SPACE, SV *unused2 = 0, SV *callback = &PL_sv_undef)
      flags: FREELIST_ONLY FREE_SPACE
   db_sync (DB *db, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_key_range (DB *db, DB_TXN_ornull *txn, SV *key, SV *key_range, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_put (DB *db, DB_TXN_ornull *txn, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: APPEND NODUPDATA NOOVERWRITE
   db_get (DB *db, DB_TXN_ornull *txn, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: CONSUME CONSUME_WAIT GET_BOTH SET_RECNO MULTIPLE READ_COMMITTED READ_UNCOMMITTED RMW
   db_pget (DB *db, DB_TXN_ornull *txn, SV *key, SV *pkey, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: CONSUME CONSUME_WAIT GET_BOTH SET_RECNO MULTIPLE READ_COMMITTED READ_UNCOMMITTED RMW
   db_del (DB *db, DB_TXN_ornull *txn, SV *key, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_txn_commit (DB_TXN *txn, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: TXN_NOSYNC TXN_SYNC
   db_txn_abort (DB_TXN *txn, SV *callback = &PL_sv_undef)

   db_c_close (DBC *dbc, SV *callback = &PL_sv_undef)
   db_c_count (DBC *dbc, SV *count, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_c_put (DBC *dbc, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: AFTER BEFORE CURRENT KEYFIRST KEYLAST NODUPDATA
   db_c_get (DBC *dbc, SV *key, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: CURRENT FIRST GET_BOTH GET_BOTH_RANGE GET_RECNO JOIN_ITEM LAST NEXT NEXT_DUP NEXT_NODUP PREV PREV_DUP PREV_NODUP SET SET_RANGE SET_RECNO READ_UNCOMMITTED MULTIPLE MULTIPLE_KEY RMW
   db_c_pget (DBC *dbc, SV *key, SV *pkey, SV *data, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_c_del (DBC *dbc, U32 flags = 0, SV *callback = &PL_sv_undef)

   db_sequence_open (DB_SEQUENCE *seq, DB_TXN_ornull *txnid, SV *key, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: CREATE EXCL
   db_sequence_close (DB_SEQUENCE *seq, U32 flags = 0, SV *callback = &PL_sv_undef)
   db_sequence_get (DB_SEQUENCE *seq, DB_TXN_ornull *txnid, int delta, SV *seq_value, U32 flags = DB_TXN_NOSYNC, SV *callback = &PL_sv_undef)
      flags: TXN_NOSYNC
   db_sequence_remove (DB_SEQUENCE *seq, DB_TXN_ornull *txnid = 0, U32 flags = 0, SV *callback = &PL_sv_undef)
      flags: TXN_NOSYNC

=head4 db_txn_finish (DB_TXN *txn, U32 flags = 0, SV *callback = &PL_sv_undef)

This is not actually a Berkeley DB function but a BDB module
extension. The background for this exytension is: It is very annoying to
have to check every single BDB function for error returns and provide a
codepath out of your transaction. While the BDB module still makes this
possible, it contains the following extensions:

When a transaction-protected function returns any operating system
error (errno > 0), BDB will set the C<TXN_DEADLOCK> flag on the
transaction. This flag is also set by Berkeley DB functions themselves
when an operation fails with LOCK_DEADLOCK, and it causes all further
operations on that transaction (including C<db_txn_commit>) to fail.

The C<db_txn_finish> request will look at this flag, and, if it is set,
will automatically call C<db_txn_abort> (setting errno to C<LOCK_DEADLOCK>
if it isn't set to something else yet). If it isn't set, it will call
C<db_txn_commit> and return the error normally.

How to use this? Easy: just write your transaction normally:

   my $txn = $db_env->txn_begin;
   db_get $db, $txn, "key", my $data;
   db_put $db, $txn, "key", $data + 1 unless $! == BDB::NOTFOUND;
   db_txn_finish $txn;
   die "transaction failed" if $!;

That is, handle only the expected errors. If something unexpected happens
(EIO, LOCK_NOTGRANTED or a deadlock in either db_get or db_put), then the remaining
requests (db_put in this case) will simply be skipped (they will fail with
LOCK_DEADLOCK) and the transaction will be aborted.

You can use the C<< $txn->failed >> method to check wether a transaction
has failed in this way and abort further processing (excluding
C<db_txn_finish>).

=head3 DB_ENV/database environment methods

Methods available on DB_ENV/$env handles:

   DESTROY (DB_ENV_ornull *env)
           CODE:
           if (env)
             env->close (env, 0);

   $int = $env->set_data_dir (const char *dir)
   $int = $env->set_tmp_dir (const char *dir)
   $int = $env->set_lg_dir (const char *dir)
   $int = $env->set_shm_key (long shm_key)
   $int = $env->set_cachesize (U32 gbytes, U32 bytes, int ncache = 0)
   $int = $env->set_flags (U32 flags, int onoff)
   $env->set_errfile (FILE *errfile = 0)
   $env->set_msgfile (FILE *msgfile = 0)
   $int = $env->set_verbose (U32 which, int onoff = 1)
   $int = $env->set_encrypt (const char *password, U32 flags = 0)
   $int = $env->set_timeout (NV timeout_seconds, U32 flags = SET_TXN_TIMEOUT)
   $int = $env->set_mp_max_openfd (int maxopenfd);
   $int = $env->set_mp_max_write (int maxwrite, int maxwrite_sleep);
   $int = $env->set_mp_mmapsize (int mmapsize_mb)
   $int = $env->set_lk_detect (U32 detect = DB_LOCK_DEFAULT)
   $int = $env->set_lk_max_lockers (U32 max)
   $int = $env->set_lk_max_locks (U32 max)
   $int = $env->set_lk_max_objects (U32 max)
   $int = $env->set_lg_bsize (U32 max)
   $int = $env->set_lg_max (U32 max)
   $int = $env->mutex_set_increment (U32 increment)
   $int = $env->mutex_set_tas_spins (U32 tas_spins)
   $int = $env->mutex_set_max (U32 max)
   $int = $env->mutex_set_align (U32 align)

   $txn = $env->txn_begin (DB_TXN_ornull *parent = 0, U32 flags = 0)
      flags: READ_COMMITTED READ_UNCOMMITTED TXN_NOSYNC TXN_NOWAIT TXN_SNAPSHOT TXN_SYNC TXN_WAIT TXN_WRITE_NOSYNC

=head4 Example:

   use AnyEvent;
   use BDB;

   our $FH; open $FH, "<&=" . BDB::poll_fileno;
   our $WATCHER = AnyEvent->io (fh => $FH, poll => 'r', cb => \&BDB::poll_cb);

   BDB::min_parallel 8;

   my $env = db_env_create;

   mkdir "bdtest", 0700;
   db_env_open
      $env,
      "bdtest",
      BDB::INIT_LOCK | BDB::INIT_LOG | BDB::INIT_MPOOL | BDB::INIT_TXN | BDB::RECOVER | BDB::USE_ENVIRON | BDB::CREATE,
      0600;

   $env->set_flags (BDB::AUTO_COMMIT | BDB::TXN_NOSYNC, 1);


=head3 DB/database methods

Methods available on DB/$db handles:

   DESTROY (DB_ornull *db)
           CODE:
           if (db)
             {
               SV *env = (SV *)db->app_private;
               db->close (db, 0);
               SvREFCNT_dec (env);
             }

   $int = $db->set_cachesize (U32 gbytes, U32 bytes, int ncache = 0)
   $int = $db->set_flags (U32 flags)
      flags: CHKSUM ENCRYPT TXN_NOT_DURABLE
             Btree: DUP DUPSORT RECNUM REVSPLITOFF
             Hash:  DUP DUPSORT
             Queue: INORDER
             Recno: RENUMBER SNAPSHOT

   $int = $db->set_encrypt (const char *password, U32 flags)
   $int = $db->set_lorder (int lorder)
   $int = $db->set_bt_minkey (U32 minkey)
   $int = $db->set_re_delim (int delim)
   $int = $db->set_re_pad (int re_pad)
   $int = $db->set_re_source (char *source)
   $int = $db->set_re_len (U32 re_len)
   $int = $db->set_h_ffactor (U32 h_ffactor)
   $int = $db->set_h_nelem (U32 h_nelem)
   $int = $db->set_q_extentsize (U32 extentsize)

   $dbc = $db->cursor (DB_TXN_ornull *txn = 0, U32 flags = 0)
      flags: READ_COMMITTED READ_UNCOMMITTED WRITECURSOR TXN_SNAPSHOT
   $seq = $db->sequence (U32 flags = 0)

=head4 Example:

   my $db = db_create $env;
   db_open $db, undef, "table", undef, BDB::BTREE, BDB::AUTO_COMMIT | BDB::CREATE | BDB::READ_UNCOMMITTED, 0600;

   for (1..1000) {
      db_put $db, undef, "key $_", "data $_";

      db_key_range $db, undef, "key $_", my $keyrange;
      my ($lt, $eq, $gt) = @$keyrange;
   }

   db_del $db, undef, "key $_" for 1..1000;

   db_sync $db;


=head3 DB_TXN/transaction methods

Methods available on DB_TXN/$txn handles:

   DESTROY (DB_TXN_ornull *txn)
           CODE:
           if (txn)
             txn->abort (txn);

   $int = $txn->set_timeout (NV timeout_seconds, U32 flags = SET_TXN_TIMEOUT)
      flags: SET_LOCK_TIMEOUT SET_TXN_TIMEOUT

   $bool = $txn->failed
   # see db_txn_finish documentation, above


=head3 DBC/cursor methods

Methods available on DBC/$dbc handles:

   DESTROY (DBC_ornull *dbc)
           CODE:
           if (dbc)
             dbc->c_close (dbc);

   $int = $cursor->set_priority ($priority = PRIORITY_*)

=head4 Example:

   my $c = $db->cursor;

   for (;;) {
      db_c_get $c, my $key, my $data, BDB::NEXT;
      warn "<$!,$key,$data>";
      last if $!;
   }

   db_c_close $c;


=head3 DB_SEQUENCE/sequence methods

Methods available on DB_SEQUENCE/$seq handles:

   DESTROY (DB_SEQUENCE_ornull *seq)
           CODE:
           if (seq)
             seq->close (seq, 0);

   $int = $seq->initial_value (db_seq_t value)
   $int = $seq->set_cachesize (U32 size)
   $int = $seq->set_flags (U32 flags)
      flags: SEQ_DEC SEQ_INC SEQ_WRAP
   $int = $seq->set_range (db_seq_t min, db_seq_t max)

=head4 Example:

   my $seq = $db->sequence;
      
   db_sequence_open $seq, undef, "seq", BDB::CREATE;
   db_sequence_get $seq, undef, 1, my $value;


=head2 SUPPORT FUNCTIONS

=head3 EVENT PROCESSING AND EVENT LOOP INTEGRATION

=over 4

=item $msg = BDB::strerror [$errno]

Returns the string corresponding to the given errno value. If no argument
is given, use C<$!>.

Note that the BDB module also patches the C<$!> variable directly, so you
should be able to get a bdb error string by simply stringifying C<$!>.

=item $fileno = BDB::poll_fileno

Return the I<request result pipe file descriptor>. This filehandle must be
polled for reading by some mechanism outside this module (e.g. Event or
select, see below or the SYNOPSIS). If the pipe becomes readable you have
to call C<poll_cb> to check the results.

See C<poll_cb> for an example.

=item BDB::poll_cb

Process some outstanding events on the result pipe. You have to call this
regularly. Returns the number of events processed. Returns immediately
when no events are outstanding. The amount of events processed depends on
the settings of C<BDB::max_poll_req> and C<BDB::max_poll_time>.

If not all requests were processed for whatever reason, the filehandle
will still be ready when C<poll_cb> returns.

Example: Install an Event watcher that automatically calls
BDB::poll_cb with high priority:

   Event->io (fd => BDB::poll_fileno,
              poll => 'r', async => 1,
              cb => \&BDB::poll_cb);

=item BDB::max_poll_reqs $nreqs

=item BDB::max_poll_time $seconds

These set the maximum number of requests (default C<0>, meaning infinity)
that are being processed by C<BDB::poll_cb> in one call, respectively
the maximum amount of time (default C<0>, meaning infinity) spent in
C<BDB::poll_cb> to process requests (more correctly the mininum amount
of time C<poll_cb> is allowed to use).

Setting C<max_poll_time> to a non-zero value creates an overhead of one
syscall per request processed, which is not normally a problem unless your
callbacks are really really fast or your OS is really really slow (I am
not mentioning Solaris here). Using C<max_poll_reqs> incurs no overhead.

Setting these is useful if you want to ensure some level of
interactiveness when perl is not fast enough to process all requests in
time.

For interactive programs, values such as C<0.01> to C<0.1> should be fine.

Example: Install an EV watcher that automatically calls
BDB::poll_cb with low priority, to ensure that other parts of the
program get the CPU sometimes even under high load.

   # try not to spend much more than 0.1s in poll_cb
   BDB::max_poll_time 0.1;

   my $bdb_poll = EV::io BDB::poll_fileno, EV::READ, \&BDB::poll_cb);

=item BDB::poll_wait

If there are any outstanding requests and none of them in the result
phase, wait till the result filehandle becomes ready for reading (simply
does a C<select> on the filehandle. This is useful if you want to
synchronously wait for some requests to finish).

See C<nreqs> for an example.

=item BDB::poll

Waits until some requests have been handled.

Returns the number of requests processed, but is otherwise strictly
equivalent to:

   BDB::poll_wait, BDB::poll_cb

=item BDB::flush

Wait till all outstanding BDB requests have been handled.

Strictly equivalent to:

   BDB::poll_wait, BDB::poll_cb
      while BDB::nreqs;

=back

=head3 CONTROLLING THE NUMBER OF THREADS

=over 4

=item BDB::min_parallel $nthreads

Set the minimum number of BDB threads to C<$nthreads>. The current
default is C<8>, which means eight asynchronous operations can execute
concurrently at any one time (the number of outstanding requests,
however, is unlimited).

BDB starts threads only on demand, when an BDB request is queued and
no free thread exists. Please note that queueing up a hundred requests can
create demand for a hundred threads, even if it turns out that everything
is in the cache and could have been processed faster by a single thread.

It is recommended to keep the number of threads relatively low, as some
Linux kernel versions will scale negatively with the number of threads
(higher parallelity => MUCH higher latency). With current Linux 2.6
versions, 4-32 threads should be fine.

Under most circumstances you don't need to call this function, as the
module selects a default that is suitable for low to moderate load.

=item BDB::max_parallel $nthreads

Sets the maximum number of BDB threads to C<$nthreads>. If more than the
specified number of threads are currently running, this function kills
them. This function blocks until the limit is reached.

While C<$nthreads> are zero, aio requests get queued but not executed
until the number of threads has been increased again.

This module automatically runs C<max_parallel 0> at program end, to ensure
that all threads are killed and that there are no outstanding requests.

Under normal circumstances you don't need to call this function.

=item BDB::max_idle $nthreads

Limit the number of threads (default: 4) that are allowed to idle (i.e.,
threads that did not get a request to process within 10 seconds). That
means if a thread becomes idle while C<$nthreads> other threads are also
idle, it will free its resources and exit.

This is useful when you allow a large number of threads (e.g. 100 or 1000)
to allow for extremely high load situations, but want to free resources
under normal circumstances (1000 threads can easily consume 30MB of RAM).

The default is probably ok in most situations, especially if thread
creation is fast. If thread creation is very slow on your system you might
want to use larger values.

=item $oldmaxreqs = BDB::max_outstanding $maxreqs

This is a very bad function to use in interactive programs because it
blocks, and a bad way to reduce concurrency because it is inexact: Better
use an C<aio_group> together with a feed callback.

Sets the maximum number of outstanding requests to C<$nreqs>. If you
to queue up more than this number of requests, the next call to the
C<poll_cb> (and C<poll_some> and other functions calling C<poll_cb>)
function will block until the limit is no longer exceeded.

The default value is very large, so there is no practical limit on the
number of outstanding requests.

You can still queue as many requests as you want. Therefore,
C<max_oustsanding> is mainly useful in simple scripts (with low values) or
as a stop gap to shield against fatal memory overflow (with large values).

=item BDB::set_sync_prepare $cb

Sets a callback that is called whenever a request is created without an
explicit callback. It has to return two code references. The first is used
as the request callback, and the second is called to wait until the first
callback has been called. The default implementation works like this:

   sub {
      my $status;
      (
         sub { $status = $! },
         sub { BDB::poll while !defined $status; $! = $status },
      )
   }

=back

=head3 STATISTICAL INFORMATION

=over 4

=item BDB::nreqs

Returns the number of requests currently in the ready, execute or pending
states (i.e. for which their callback has not been invoked yet).

Example: wait till there are no outstanding requests anymore:

   BDB::poll_wait, BDB::poll_cb
      while BDB::nreqs;

=item BDB::nready

Returns the number of requests currently in the ready state (not yet
executed).

=item BDB::npending

Returns the number of requests currently in the pending state (executed,
but not yet processed by poll_cb).

=back

=cut

set_sync_prepare {
   my $status;
   (
      sub {
         $status = $!;
      },
      sub {
         BDB::poll while !defined $status;
         $! = $status;
      },
   )
};

min_parallel 8;

END { flush }

1;

=head2 FORK BEHAVIOUR

This module should do "the right thing" when the process using it forks:

Before the fork, BDB enters a quiescent state where no requests
can be added in other threads and no results will be processed. After
the fork the parent simply leaves the quiescent state and continues
request/result processing, while the child frees the request/result queue
(so that the requests started before the fork will only be handled in the
parent). Threads will be started on demand until the limit set in the
parent process has been reached again.

In short: the parent will, after a short pause, continue as if fork had
not been called, while the child will act as if BDB has not been used
yet.

Win32 note: there is no fork on win32, and perls emulation of it is too
broken to be supported, so do not use BDB in a windows pseudo-fork, better
yet, switch to a more capable platform.

=head2 MEMORY USAGE

Per-request usage:

Each aio request uses - depending on your architecture - around 100-200
bytes of memory. In addition, stat requests need a stat buffer (possibly
a few hundred bytes), readdir requires a result buffer and so on. Perl
scalars and other data passed into aio requests will also be locked and
will consume memory till the request has entered the done state.

This is not awfully much, so queuing lots of requests is not usually a
problem.

Per-thread usage:

In the execution phase, some aio requests require more memory for
temporary buffers, and each thread requires a stack and other data
structures (usually around 16k-128k, depending on the OS).

=head1 KNOWN BUGS

Known bugs will be fixed in the next release, except:

   If you use a transaction in any request, and the request returns
   with an operating system error or DB_LOCK_NOTGRANTED, the internal
   TXN_DEADLOCK flag will be set on the transaction. See C<db_txn_finish>,
   above.

=head1 SEE ALSO

L<Coro::BDB>, L<IO::AIO>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

