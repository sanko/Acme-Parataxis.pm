use v5.40;
use Test2::V0 '!subtest';
use Test2::Util::Importer 'Test2::Tools::Subtest' => ( subtest_streamed => { -as => 'subtest' } );
use Acme::Parataxis;
#
ok $Acme::Parataxis::VERSION, 'Acme::Parataxis::VERSION';
#
done_testing;
