use ExtUtils::MakeMaker;
WriteMakefile(
    NAME         => 'cpantester',
    VERSION_FROM => 'cpantester.pl',
    PREREQ_PM    => { Test::Reporter => 0 },
    ($] >= 5.005 
      ? (ABSTRACT_FROM => 'cpantester.pl') : ()
    ),
);
