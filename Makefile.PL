use ExtUtils::MakeMaker;

use Config;

if ($^O =~ /linux/ && $Config{usemymalloc} eq "y") {
   print <<EOF;

***
*** WARNING:
***
*** Your perl uses it's own memory allocator (-Dusemymalloc=y),
*** which is known not to be threadsafe on GNU/Linux and probably
*** other platforms (even when not used concurrently, it trashes
*** the data structures of the system malloc running concurrently),
*** for perls up to 5.8.8 and possibly later versions.
***
*** If you are unsure wether your perl has been fixed, your system
*** is safe for other reasons, or you experience spurious segfaults,
*** please compile your perl with -Dusemymalloc=n.
***

EOF
}

my $mm = MM->new({
    dist         => {
       PREOP	=> 'pod2text AIO.pm | tee README >$(DISTVNAME)/README; chmod -R u=rwX,go=rX . ;',
       COMPRESS	=> 'gzip -9v',
       SUFFIX	=> '.gz',
	            },
    NAME         => "BDB",
    VERSION_FROM => "BDB.pm",
    LIBS         => ['-lpthread -ldb'],
    PM           => {
    		    'BDB.pm'		=> '$(INST_LIBDIR)/BDB.pm',
                    },
});

$mm->flush;

