=head1 NAME

BDB - Asynchronous Berkeley DB access

=head1 SYNOPSIS

 use BDB;

=head1 DESCRIPTION

See the eg/ directory in the distribution and the berkeleydb C
documentation. This is inadequate, but the only sources of documentation
known for this module so far.

=head2 EXAMPLE

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
   our $VERSION = '0.1';

   our @BDB_REQ = qw(
      db_env_open db_env_close db_env_txn_checkpoint db_env_lock_detect
      db_env_memp_sync db_env_memp_trickle
      db_open db_close db_compact db_sync db_put db_get db_pget db_del db_key_range
      db_txn_commit db_txn_abort
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

=head2 SUPPORT FUNCTIONS

=head3 EVENT PROCESSING AND EVENT LOOP INTEGRATION

=over 4

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

Example: Install an Event watcher that automatically calls
BDB::poll_cb with low priority, to ensure that other parts of the
program get the CPU sometimes even under high AIO load.

   # try not to spend much more than 0.1s in poll_cb
   BDB::max_poll_time 0.1;

   # use a low priority so other tasks have priority
   Event->io (fd => BDB::poll_fileno,
              poll => 'r', nice => 1,
              cb => &BDB::poll_cb);

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

Wait till all outstanding AIO requests have been handled.

Strictly equivalent to:

   BDB::poll_wait, BDB::poll_cb
      while BDB::nreqs;

=head3 CONTROLLING THE NUMBER OF THREADS

=item BDB::min_parallel $nthreads

Set the minimum number of AIO threads to C<$nthreads>. The current
default is C<8>, which means eight asynchronous operations can execute
concurrently at any one time (the number of outstanding requests,
however, is unlimited).

BDB starts threads only on demand, when an AIO request is queued and
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

Sets the maximum number of AIO threads to C<$nthreads>. If more than the
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

Before the fork, IO::AIO enters a quiescent state where no requests
can be added in other threads and no results will be processed. After
the fork the parent simply leaves the quiescent state and continues
request/result processing, while the child frees the request/result queue
(so that the requests started before the fork will only be handled in the
parent). Threads will be started on demand until the limit set in the
parent process has been reached again.

In short: the parent will, after a short pause, continue as if fork had
not been called, while the child will act as if IO::AIO has not been used
yet.

=head2 MEMORY USAGE

Per-request usage:

Each aio request uses - depending on your architecture - around 100-200
bytes of memory. In addition, stat requests need a stat buffer (possibly
a few hundred bytes), readdir requires a result buffer and so on. Perl
scalars and other data passed into aio requests will also be locked and
will consume memory till the request has entered the done state.

This is now awfully much, so queuing lots of requests is not usually a
problem.

Per-thread usage:

In the execution phase, some aio requests require more memory for
temporary buffers, and each thread requires a stack and other data
structures (usually around 16k-128k, depending on the OS).

=head1 KNOWN BUGS

Known bugs will be fixed in the next release.

=head1 SEE ALSO

L<Coro::AIO>.

=head1 AUTHOR

 Marc Lehmann <schmorp@schmorp.de>
 http://home.schmorp.de/

=cut

