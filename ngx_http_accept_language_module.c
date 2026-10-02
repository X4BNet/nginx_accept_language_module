#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>

static char *ngx_http_accept_language(ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static ngx_int_t ngx_http_accept_language_variable(ngx_http_request_t *r, ngx_http_variable_value_t *v, uintptr_t data);

static ngx_command_t  ngx_http_accept_language_commands[] = {

    { ngx_string("set_from_accept_language"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_1MORE,
      ngx_http_accept_language,
      NGX_HTTP_MAIN_CONF_OFFSET,
      0,
      NULL },
      ngx_null_command
};

typedef struct ngx_http_accept_language_s {
  ngx_hash_t hash;
  ngx_str_t default_language;
  size_t max_language_len;
} ngx_http_accept_language_t;

// No need for any configuration callback
static ngx_http_module_t  ngx_http_accept_language_module_ctx = {
    NULL,  NULL, NULL, NULL,  NULL, NULL, NULL, NULL 
};

ngx_module_t  ngx_http_accept_language_module = {
    NGX_MODULE_V1,
    &ngx_http_accept_language_module_ctx,       /* module context */
    ngx_http_accept_language_commands,          /* module directives */
    NGX_HTTP_MODULE,                       /* module type */
    NULL,                                  /* init master */
    NULL,                                  /* init module */
    NULL,                                  /* init process */
    NULL,                                  /* init thread */
    NULL,                                  /* exit thread */
    NULL,                                  /* exit process */
    NULL,                                  /* exit master */
    NGX_MODULE_V1_PADDING
};

static char * ngx_http_accept_language(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
  ngx_uint_t          i;
  ngx_str_t           *value, *snew, name, key;
  ngx_http_variable_t *var;
  ngx_hash_init_t  hash;
  ngx_http_accept_language_t *al;
  ngx_hash_keys_arrays_t  hash_keys;

  value = cf->args->elts;
  name = value[1];
  
  if (name.data[0] != '$') {
      ngx_conf_log_error(NGX_LOG_WARN, cf, 0, "\"%V\" variable name should start with '$'", &name);
  } else {
      name.len--;
      name.data++;
  }
  
  var = ngx_http_add_variable(cf, &name, NGX_HTTP_VAR_CHANGEABLE);
  if (var == NULL) {
      return NGX_CONF_ERROR;
  }
  if (var->get_handler != NULL) {
    ngx_conf_log_error(NGX_LOG_EMERG, cf, 0, "variable already defined: \"%V\"", &name);
    return NGX_CONF_ERROR;
  }
  
  var->get_handler = ngx_http_accept_language_variable;

  /* Build one hash per HTTP-level variable, shared by all HTTP servers. */
  al = ngx_pcalloc(cf->pool, sizeof(ngx_http_accept_language_t));
  if (al == NULL) {
      return NGX_CONF_ERROR;
  }
  
  hash_keys.pool = cf->pool;
  hash_keys.temp_pool = cf->temp_pool;

  if (ngx_hash_keys_array_init(&hash_keys, NGX_HASH_SMALL) != NGX_OK) {
    return NGX_CONF_ERROR;
  }
  
  for (i = 2; i < cf->args->nelts; i++) {
    if(al->default_language.len == 0){
      al->default_language = value[i];
    }
    if (value[i].len > al->max_language_len) {
      al->max_language_len = value[i].len;
    }
    snew = ngx_palloc(cf->pool, sizeof(ngx_str_t));
    if (snew == NULL) {
      return NGX_CONF_ERROR;
    }
    *snew = value[i];

    /* Hash lowercase keys without changing the configured return value. */
    key.len = snew->len;
    key.data = ngx_pstrdup(cf->temp_pool, snew);
    if (key.data == NULL
        || ngx_hash_add_key(&hash_keys, &key, snew, 0) == NGX_ERROR)
    {
      return NGX_CONF_ERROR;
    }
  }

  hash.hash = &al->hash;
  hash.key = ngx_hash_key_lc;
  hash.max_size = 512;
  hash.bucket_size = ngx_align(64, ngx_cacheline_size);
  hash.name = "accept_key_hash";
  hash.pool = cf->pool;
  hash.temp_pool = cf->temp_pool;

  if(ngx_hash_init(&hash, hash_keys.keys.elts, hash_keys.keys.nelts) != NGX_OK) {
      return NGX_CONF_ERROR;
  }

  var->data = (uintptr_t)al;
  
  return NGX_CONF_OK;
}

static ngx_str_t *
ngx_http_accept_language_lookup(ngx_http_accept_language_t *al, u_char *range,
    size_t len)
{
  u_char          c;
  size_t          i, subtag;
  ngx_uint_t      key, first;
  ngx_hash_elt_t *elt;

  if (len == 0 || al->hash.size == 0) {
    return NULL;
  }

  /* RFC 4647 section 2.1: accept basic ranges only.  Skip "*" and
   * extended/invalid ranges rather than truncating them into a match. */
  subtag = 0;
  first = 1;
  for (i = 0; i < len; i++) {
    c = ngx_tolower(range[i]);
    if (c == '-') {
      if (subtag == 0) {
        return NULL;
      }
      subtag = 0;
      first = 0;
    } else {
      if (!((c >= 'a' && c <= 'z')
            || (!first && c >= '0' && c <= '9'))
          || ++subtag > 8)
      {
        return NULL;
      }
    }
  }
  if (subtag == 0) {
    return NULL;
  }

  while (len != 0) {
    /* Longer candidates cannot match.  Avoid repeatedly hashing a long
     * client-supplied range while truncating it to a supported length. */
    if (len <= al->max_language_len) {
      key = ngx_hash_key_lc(range, len);
      elt = al->hash.buckets[key % al->hash.size];

      /* ngx_hash_find requires a lowercase input.  Compare the bucket
       * case-insensitively without copying or modifying the request header. */
      if (elt != NULL) {
        while (elt->value != NULL) {
          if (len == (size_t) elt->len
              && ngx_strncasecmp(range, elt->name, len) == 0)
          {
            return elt->value;
          }
          elt = (ngx_hash_elt_t *) ngx_align_ptr(elt->name + elt->len,
                                               sizeof(void *));
        }
      }
    }

    /* RFC 4647 section 3.4: remove the rightmost subtag, together
     * with any singleton (extension or private-use marker) left at the end. */
    do {
      while (len != 0 && range[len - 1] != '-') {
        len--;
      }
      if (len != 0) {
        len--;
      }
    } while (len == 1 || (len >= 2 && range[len - 2] == '-'));
  }

  return NULL;
}

static ngx_int_t ngx_http_accept_language_variable(ngx_http_request_t *r, ngx_http_variable_value_t *v, uintptr_t data)
{
  u_char            *start, *pos, *end, *range_end;
  ngx_http_accept_language_t    *al = (ngx_http_accept_language_t *) data;
  ngx_str_t         *l;


  if ( NULL != r->headers_in.accept_language ) {       
    start = r->headers_in.accept_language->value.data;
    end = start + r->headers_in.accept_language->value.len;

    while (start < end) {
      while (start < end && (*start == ' ' || *start == '\t')) {start++; }
      
      pos = start;
    
      while (pos < end && *pos != ',' && *pos != ';') { pos++; }
    
      range_end = pos;
      while (range_end > start
             && (range_end[-1] == ' ' || range_end[-1] == '\t'))
      {
        range_end--;
      }

      l = ngx_http_accept_language_lookup(al, start, range_end - start);
      if(l != NULL){
        v->data = l->data;
        v->len  = l->len;
        goto set;
      }
    
      // We discard the quality value
      if (pos < end && *pos == ';') {
        while (pos < end && *pos != ',') {pos++; }
      }
      if (pos < end && *pos == ',') {
        pos++;
      }
      
      start = pos;
    }
  }

  v->data = al->default_language.data;
  v->len  = al->default_language.len;

set:
  /* Set all required params */
  v->valid = 1;
  v->no_cacheable = 0;
  v->not_found = 0;
  return NGX_OK; 
}
