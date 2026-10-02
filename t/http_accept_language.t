use strict;
use warnings;
use Test::Nginx::Socket 'no_plan';

repeat_each(1);
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;
    $block->set_value('http_config', 'set_from_accept_language $lang en ja pl pt-br;')
        unless defined $block->http_config;
    $block->set_value('config', 'location = /language { return 200 "$lang\n"; }');
    $block->set_value('no_error_log', "[error]\n[alert]\n[crit]");
});

run_tests();

__DATA__

=== TEST 1: missing header uses the first configured language
--- request
GET /language
--- response_body
en


=== TEST 2: an empty header uses the default
--- request
GET /language
--- more_headers
Accept-Language:
--- response_body
en


=== TEST 3: an unsupported language uses the default
--- request
GET /language
--- more_headers
Accept-Language: fr
--- response_body
en


=== TEST 4: a supported language overrides the default
--- request
GET /language
--- more_headers
Accept-Language: ja
--- response_body
ja


=== TEST 5: regional language tags match exactly
--- request
GET /language
--- more_headers
Accept-Language: pt-br
--- response_body
pt-br


=== TEST 6: a language prefix does not match a configured regional tag
--- request
GET /language
--- more_headers
Accept-Language: pt
--- response_body
en


=== TEST 7: the first supported preference wins
--- request
GET /language
--- more_headers
Accept-Language: ja,pl,en
--- response_body
ja


=== TEST 8: unsupported preferences are skipped
--- request
GET /language
--- more_headers
Accept-Language: fr,pl,ja
--- response_body
pl


=== TEST 9: a supported language with a quality suffix matches
--- request
GET /language
--- more_headers
Accept-Language: ja;q=0.8
--- response_body
ja


=== TEST 10: quality suffixes on skipped and matched preferences are ignored
--- request
GET /language
--- more_headers
Accept-Language: fr;q=1.0,pl;q=0.8,ja;q=0.5
--- response_body
pl


=== TEST 11: preferences are not reordered by quality
--- request
GET /language
--- more_headers
Accept-Language: ja;q=0.1,pl;q=1.0
--- response_body
ja


=== TEST 12: spaces between preferences are skipped
--- request
GET /language
--- more_headers
Accept-Language: fr,   ja, pl
--- response_body
ja


=== TEST 13: no supported preferences uses the default
--- request
GET /language
--- more_headers
Accept-Language: fr;q=0.9,de;q=0.8
--- response_body
en


=== TEST 14: empty list entries and a trailing comma are skipped
--- request
GET /language
--- more_headers
Accept-Language: , ,ja,,
--- response_body
ja


=== TEST 15: wildcard falls back to the first configured language
--- request
GET /language
--- more_headers
Accept-Language: *
--- response_body
en


=== TEST 16: default follows configuration order
--- http_config
set_from_accept_language $lang pl en ja;
--- request
GET /language
--- response_body
pl


=== TEST 17: language selection is independent for requests on one connection
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: ja", "Accept-Language: pl", ""]
--- response_body eval
["ja\n", "pl\n", "en\n"]
