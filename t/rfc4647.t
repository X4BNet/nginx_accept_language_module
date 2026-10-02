use strict;
use warnings;
use Test::Nginx::Socket 'no_plan';

repeat_each(1);
no_shuffle();

add_block_preprocessor(sub {
    my ($block) = @_;
    $block->set_value('http_config', 'set_from_accept_language $lang en de de-DE;')
        unless defined $block->http_config;
    $block->set_value('config', 'location = /language { return 200 "$lang\n"; }')
        unless defined $block->config;
    $block->set_value('no_error_log', "[error]\n[alert]\n[crit]");
});

run_tests();

__DATA__

=== TEST 1: exact regional match wins over its configured parent
--- request
GET /language
--- more_headers
Accept-Language: de-DE
--- response_body
de-DE


=== TEST 2: a regional range falls back to its parent
--- http_config
set_from_accept_language $lang en de;
--- request
GET /language
--- more_headers
Accept-Language: de-DE
--- response_body
de


=== TEST 3: matching is case insensitive and preserves configured spelling
--- http_config
set_from_accept_language $lang en DE-de;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: de-DE", "Accept-Language: DE-DE", "Accept-Language: de-de"]
--- response_body eval
["DE-de\n", "DE-de\n", "DE-de\n"]


=== TEST 4: the default also preserves configured spelling
--- http_config
set_from_accept_language $lang DE-de en;
--- request
GET /language
--- response_body
DE-de


=== TEST 5: fallbacks finish before trying the next preference
--- http_config
set_from_accept_language $lang en de fr-FR;
--- request
GET /language
--- more_headers
Accept-Language: de-DE,fr-FR
--- response_body
de


=== TEST 6: an exhausted fallback proceeds to the next preference
--- request
GET /language
--- more_headers
Accept-Language: zh-Hant-CN,DE-at,en
--- response_body
de


=== TEST 7: a three-subtag range prefers the longest supported prefix
--- http_config
set_from_accept_language $lang en zh zh-Hant zh-Hant-CN;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: ZH-hant-cn",
    "Accept-Language: zh-Hant-TW",
    "Accept-Language: zh-Hans-CN",
]
--- response_body eval
["zh-Hant-CN\n", "zh-Hant\n", "zh\n"]


=== TEST 8: RFC private-use example visits each permitted fallback
--- http_config
set_from_accept_language $lang en zh zh-Hant zh-Hant-CN zh-Hant-CN-x-private1 zh-Hant-CN-x-private1-private2;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: zh-Hant-CN-x-private1-private2",
    "Accept-Language: zh-Hant-CN-x-private1-other",
    "Accept-Language: zh-Hant-CN-x-other",
    "Accept-Language: zh-Hant-TW-x-other",
    "Accept-Language: zh-Hans-TW-x-other",
]
--- response_body eval
["zh-Hant-CN-x-private1-private2\n", "zh-Hant-CN-x-private1\n", "zh-Hant-CN\n", "zh-Hant\n", "zh\n"]


=== TEST 9: truncation removes letter and digit singleton markers
--- http_config
set_from_accept_language $lang en de de-x de-u de-0;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: de-x-private",
    "Accept-Language: de-u-co-phonebk",
    "Accept-Language: de-0-example",
]
--- response_body eval
["de\n", "de\n", "de\n"]


=== TEST 10: singleton primary subtags are also removed with their payload
--- http_config
set_from_accept_language $lang en x i de;
--- pipelined_requests eval
["GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: x-private,de", "Accept-Language: i-klingon,de"]
--- response_body eval
["de\n", "de\n"]


=== TEST 11: exact extension tags still match before any truncation
--- http_config
set_from_accept_language $lang en de de-u-co de-u-co-phonebk;
--- pipelined_requests eval
["GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: de-u-co-phonebk", "Accept-Language: de-u-co-other"]
--- response_body eval
["de-u-co-phonebk\n", "de-u-co\n"]


=== TEST 12: adjacent singleton subtags are not left dangling
--- http_config
set_from_accept_language $lang en de de-a de-a-b;
--- request
GET /language
--- more_headers
Accept-Language: de-a-b-private
--- response_body
de


=== TEST 13: lookup does not expand a range into a more specific tag
--- http_config
set_from_accept_language $lang en de-CH-1996;
--- pipelined_requests eval
["GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: de", "Accept-Language: de-CH"]
--- response_body eval
["en\n", "en\n"]


=== TEST 14: truncation occurs only at whole subtag boundaries
--- http_config
set_from_accept_language $lang en de-DE;
--- request
GET /language
--- more_headers
Accept-Language: de-Deva
--- response_body
en


=== TEST 15: lookup does not skip an intermediate script subtag
--- http_config
set_from_accept_language $lang en de-DE de;
--- request
GET /language
--- more_headers
Accept-Language: de-Latn-DE
--- response_body
de


=== TEST 16: wildcard ranges defer to subsequent preferences
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: *,de-DE",
    "Accept-Language: fr,*,DE-at",
    "Accept-Language: fr,*,zh-Hant",
]
--- response_body eval
["de-DE\n", "de\n", "en\n"]


=== TEST 17: unsupported extended ranges are skipped without falling back
--- http_config
set_from_accept_language $lang en de fr;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: de-*-DE,fr",
    "Accept-Language: de-*,fr",
    "Accept-Language: *-DE,fr",
]
--- response_body eval
["fr\n", "fr\n", "fr\n"]


=== TEST 18: malformed ranges are skipped without matching a valid prefix
--- http_config
set_from_accept_language $lang en de fr;
--- pipelined_requests eval
[("GET /language") x 10]
--- more_headers eval
[
    "Accept-Language: de-,fr",
    "Accept-Language: de--DE,fr",
    "Accept-Language: de-DE!,fr",
    "Accept-Language: de-DE_extra,fr",
    "Accept-Language: de-123456789,fr",
    "Accept-Language: de- DE,fr",
    "Accept-Language: 1de-DE,fr",
    "Accept-Language: abcdefghi-DE,fr",
    "Accept-Language: -de-DE,fr",
    "Accept-Language: de-\xE9,fr",
]
--- response_body eval
[("fr\n") x 10]


=== TEST 19: numeric subtags are supported
--- http_config
set_from_accept_language $lang en es es-419 de de-1996;
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: es-419",
    "Accept-Language: es-419-x-private",
    "Accept-Language: de-1996-x-private",
]
--- response_body eval
["es-419\n", "es-419\n", "de-1996\n"]


=== TEST 20: spaces and tabs around ranges and quality suffixes are ignored
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: fr,\t DE-de \t;q=0.8,en",
    "Accept-Language: fr,\t DE-at \t,en",
    "Accept-Language: ,\t, ;q=0.8, DE-at \t;q=0.7,",
]
--- response_body eval
["de-DE\n", "de\n", "de\n"]


=== TEST 21: quality suffixes preserve the existing header-order priority
--- http_config
set_from_accept_language $lang en de fr;
--- request
GET /language
--- more_headers
Accept-Language: de-DE;q=0.1,fr;q=1.0
--- response_body
de


=== TEST 22: default is used only after exhausting all ranges
--- http_config
set_from_accept_language $lang en de;
--- pipelined_requests eval
["GET /language", "GET /language"]
--- more_headers eval
[
    "Accept-Language: fr-FR,zh-Hant-CN,de-AT",
    "Accept-Language: fr-FR,zh-Hant-CN,*",
]
--- response_body eval
["de\n", "en\n"]


=== TEST 23: matching does not mutate the header or affect other variables
--- http_config
set_from_accept_language $lang en de;
set_from_accept_language $other en de-DE;
--- config
location = /language { return 200 "$lang|$other|$http_accept_language\n"; }
--- request
GET /language
--- more_headers
Accept-Language: DE-de-x-private;q=0.8,fr
--- response_body
de|de-DE|DE-de-x-private;q=0.8,fr


=== TEST 24: long ranges can fall back without a fixed buffer limit
--- request
GET /language
--- more_headers eval
"Accept-Language: de-DE" . ("-abcdefgh" x 300)
--- response_body
de-DE


=== TEST 25: empty and wildcard entries safely reach the default
--- pipelined_requests eval
["GET /language", "GET /language", "GET /language"]
--- more_headers eval
["Accept-Language: ,\t,;q=0.5,", "Accept-Language: *,*,", "Accept-Language: -"]
--- response_body eval
["en\n", "en\n", "en\n"]
