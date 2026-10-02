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


=== TEST 18: a supported language in the second field is selected
--- request
GET /language
--- more_headers
Accept-Language: fr
Accept-Language: ja
--- response_body
ja


=== TEST 19: all repeated fields are searched in order regardless of name casing
--- request
GET /language
--- more_headers
Accept-Language: fr
accept-language: *
ACCEPT-LANGUAGE: PL
Accept-Language: ja
--- response_body
pl


=== TEST 20: repeated fields behave like a single comma-separated field
--- pipelined_requests eval
["GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: fr,es;q=0.9\nAccept-Language: pl;q=0.8,ja;q=0.7",
    "Accept-Language: fr,es;q=0.9,pl;q=0.8,ja;q=0.7",
]
--- response_body eval
["pl\n", "pl\n"]


=== TEST 21: empty fields do not prevent matching later fields
--- request
GET /language
--- more_headers eval
"Accept-Language:\nAccept-Language: \t\nAccept-Language: ja"
--- response_body
ja


=== TEST 22: a fallback in an earlier field wins over a later exact match
--- request
GET /language
--- more_headers
Accept-Language: ja-JP
Accept-Language: pl
--- response_body
ja


=== TEST 23: later fields use RFC 4647 fallback and case-insensitive matching
--- request
GET /language
--- more_headers
Accept-Language: fr-FR
Accept-Language: PT-BR-x-private
Accept-Language: ja
--- response_body
pt-br


=== TEST 24: quality suffixes do not reorder preferences across fields
--- request
GET /language
--- more_headers
Accept-Language: pl;q=0.1
Accept-Language: ja;q=1.0
--- response_body
pl


=== TEST 25: repeated fields remain independent across requests on a connection
--- pipelined_requests eval
[("GET /language") x 5]
--- more_headers eval
[
    "Accept-Language: fr\nAccept-Language: ja",
    "Accept-Language: pl",
    "",
    "Accept-Language: ja-*,ja-\nAccept-Language: PT-br",
    "Accept-Language: fr\nAccept-Language: de-DE\nAccept-Language: *",
]
--- response_body eval
["ja\n", "pl\n", "en\n", "pt-br\n", "en\n"]


=== TEST 26: field boundaries separate tokens instead of joining their bytes
--- request
GET /language
--- more_headers
Accept-Language: pt-
Accept-Language: br,ja
--- response_body
ja


=== TEST 27: unrelated fields between language fields do not affect selection
--- request
GET /language
--- more_headers eval
"Accept-Language: fr\n"
    . CORE::join("\n", map { "X-Filler-$_: ignored" } 1..40)
    . "\nAccept-Language: pl\nAccept-Language: ja"
--- response_body
pl
