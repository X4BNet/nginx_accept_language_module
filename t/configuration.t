use strict;
use warnings;
use Test::Nginx::Socket 'no_plan';

repeat_each(1);
no_shuffle();
run_tests();

__DATA__

=== TEST 1: server-level declarations are rejected
--- config
set_from_accept_language $lang en ja;
--- must_die: 1
--- error_log
"set_from_accept_language" directive is not allowed here


=== TEST 2: location-level declarations are rejected
--- config
location = /language {
    set_from_accept_language $lang en ja;
}
--- must_die: 1
--- error_log
"set_from_accept_language" directive is not allowed here


=== TEST 3: duplicate HTTP-level variables are rejected
--- http_config
set_from_accept_language $lang en ja;
set_from_accept_language $lang pl;
--- config
--- must_die: 1
--- error_log
variable already defined: "lang"


=== TEST 4: HTTP variables work in all servers and locations regardless of declaration order
--- http_config
server {
    listen $TEST_NGINX_SERVER_PORT;
    server_name first.test;
    location = /language { return 200 "$server_name:$lang|$other\n"; }
    location /nested { return 200 "$server_name:$lang|$other\n"; }
}
set_from_accept_language $lang en ja;
set_from_accept_language $other de pl;
--- server_name: second.test
--- config
location = /language { return 200 "$server_name:$lang|$other\n"; }
location /nested { return 200 "$server_name:$lang|$other\n"; }
--- pipelined_requests eval
[
    "GET /language", "GET /nested", "GET /language", "GET /nested",
    "GET /language", "GET /nested", "GET /language", "GET /nested",
]
--- more_headers eval
[
    "Host: first.test\nAccept-Language: ja",
    "Host: first.test\nAccept-Language: pl",
    "Host: first.test\nAccept-Language: zh",
    "Host: first.test",
    "Host: second.test\nAccept-Language: ja",
    "Host: second.test\nAccept-Language: pl",
    "Host: second.test\nAccept-Language: zh",
    "Host: second.test",
]
--- response_body eval
[
    "first.test:ja|de\n", "first.test:en|pl\n",
    "first.test:en|de\n", "first.test:en|de\n",
    "second.test:ja|de\n", "second.test:en|pl\n",
    "second.test:en|de\n", "second.test:en|de\n",
]
--- no_error_log
[error]
[alert]
[crit]
