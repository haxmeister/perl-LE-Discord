use strict;
use warnings;
use ExtUtils::MakeMaker;

die "LE::Discord requires Linux\n" unless $^O eq 'linux';

WriteMakefile(
    NAME => 'LE::Discord',
    VERSION_FROM => 'lib/LE/Discord.pm',
    ABSTRACT => 'Discord REST client for Linux::Event',
    AUTHOR => 'Joshua S. Day',
    LICENSE => 'mit',
    MIN_PERL_VERSION => '5.036000',
    PREREQ_PM => {
        'Linux::Event'       => '0.117',
        'Linux::Event::HTTP' => '0.005',
        'JSON::PP' => 0,
        'URI::Escape' => 0,
        'Time::HiRes' => 0,
    },
    TEST_REQUIRES => { 'Test::More' => 0 },
);
