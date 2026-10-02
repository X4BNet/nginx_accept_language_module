# Nginx Accept Language module

This module parses the Accept-Language header and gives the most suitable locale for the user from a list of supported locales from your website.

## Syntax

```nginx
set_from_accept_language $lang en ja pl;
```

- `$lang` is the variable in which to store the locale.
- `en ja pl` are the locales supported by your website.

Context: `http`. Define each variable once in the `http` block; its language hash is built once and shared by all HTTP servers and locations.

`set_from_accept_language` is not allowed in `server` or `location` blocks. Move existing declarations into `http`.

If none of the locales from `accept_language` is available on your website, it sets the variable to the first locale of your website's supported locales (in this case `en`).

### Language matching

The module uses [RFC 4647 lookup (section 3.4)](https://www.rfc-editor.org/rfc/rfc4647.html#section-3.4). Each header preference is matched case-insensitively, first as a complete tag and then by removing subtags from the right. For example, `de-DE` tries `de-DE` before `de`, and `zh-Hant-CN` tries `zh-Hant-CN`, `zh-Hant`, then `zh`. All fallbacks for one preference are tried before moving to the next preference.

When truncation leaves a single-letter or single-digit subtag at the end, that subtag is removed too. For example, `zh-Hant-CN-x-private1-private2` tries the full tag, `zh-Hant-CN-x-private1`, `zh-Hant-CN`, `zh-Hant`, then `zh`.

Lookup only selects complete configured tags: `de` does not select `de-DE`. The selected value retains its configured spelling. A wildcard (`*`) is skipped so subsequent preferences can be tried; if nothing matches, the first configured locale is returned. Extended ranges such as `de-*-DE` and malformed basic ranges are ignored.

### Caveat

Preferences are processed in header order. Quality (`q`) values are discarded, including `q=0`, so callers must supply preferences in the desired order and omit unacceptable ranges. RFC 4647 defines language matching separately from the priority-list syntax; this module does not implement HTTP quality weighting.

## Example configuration

If you have different subdomains for each language:

```nginx
http {
    set_from_accept_language $lang en ja zh;

    server {
        listen 80;
        server_name your_domain.com;
        rewrite ^/(.*) http://$lang.your_domain.com redirect;
    }
}
```

Or you could do something like this, redirecting people coming to `/` to `/en` (or `/pt`):

```nginx
http {
    set_from_accept_language $lang pt en;

    server {
        listen 80;
        server_name your_domain.com;

        location / {
            if ( $request_uri ~ ^/$ ) {
                rewrite ^/$ /$lang redirect;
                break;
            }
        }
    }
}
```

## Tests

The behavioral and configuration tests use [Test::Nginx::Socket](https://metacpan.org/pod/Test::Nginx::Socket) and Perl's `prove` runner. Build nginx with this module and install Test::Nginx, then run:

```bash
cpanm Test::Nginx
TEST_NGINX_BINARY=/path/to/nginx prove -v t/*.t
```

The suite covers defaults, RFC 4647 lookup and singleton truncation, case-insensitive matching, wildcards, malformed ranges, ordered preferences, quality suffixes, HTTP-only configuration, and sharing across servers and locations. It starts its own nginx on port 1984; set `TEST_NGINX_SERVER_PORT` to use another port.

GitHub Actions builds nginx 1.26.3 and 1.30.5 with the module and runs the suite on pushes and pull requests. The workflow can also be started manually.

## Benchmarks

See [bench/README.md](bench/README.md) for reproducible handler and HTTP throughput benchmarks with 1, 10, 100 and 200 accepted languages.

## Why did I create it?

I'm using page caching with merb on a multi-lingual website and I needed a way to serve the correct language page from the cache.
I'll soon put an example on [gom-jabbar.org](http://gom-jabbar.org).

## Bugs

Send bugs to Guillaume Maury ([dev@gom-jabbar.org](mailto:dev@gom-jabbar.org)).

## Acknowledgement

Thanks to Evan Miller for his [guide on writing nginx modules](http://emiller.info/nginx-modules-guide.html).
