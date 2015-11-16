#include "21-date.h"

#if !ICICLE_NO_PSV

/* forward declarations for types, implemented by generated code */
typedef struct ifleet ifleet_t;

/* psv types */
typedef const char * psv_error_t;

typedef struct {
    /* inputs */
    /* these are 32-bit file handles, but storing them as 64-bit in the struct makes it easier to poke from Haskell */
    iint_t input_fd;
    iint_t output_fd;

    /* outputs */
    psv_error_t error;
} psv_config_t;

typedef struct {
    /* input buffer */
    const char *buffer_ptr;
    size_t      buffer_size;
    size_t      buffer_remaining;

    /* current entity */
    char       *entity_cur;      /* invariant: these must point to a block of memory at least */
    size_t      entity_cur_size; /*            as large as the input buffer or we'll overflow */

    /* fleet state */
    ifleet_t   *fleet;

    /* output file descriptor */
    int         output_fd;
} psv_state_t;


/* forward declarations for functions, implemented by generated code */
static ifleet_t * INLINE psv_alloc_fleet ();

static void INLINE psv_collect_fleet (ifleet_t *fleet);

static void INLINE psv_write_outputs (int fd, const char *entity, ifleet_t *fleet);

static psv_error_t INLINE psv_read_fact
  ( ifleet_t     *fleet
  , const char   *attrib
  , const size_t  attrib_size
  , const char   *value
  , const size_t  value_size
  , idate_t       date );

/* psv driver */
static const size_t psv_max_row_count = 128;
static const size_t psv_buffer_size   = 16*1024;

static psv_error_t psv_alloc_error (const char *msg, const char *value_ptr, const size_t value_size)
{
    size_t  error_size = 4 * 1024;
    char   *error_text = calloc (error_size, 1);

    if (value_ptr) {
        char value_text[4*1024] = {0};
        memcpy (value_text, value_ptr, MIN (value_size, sizeof (value_text) - 1));

        snprintf (error_text, error_size, "psv_error: %s: %s\n", msg, value_text);
    } else {
        snprintf (error_text, error_size, "psv_error: %s\n", msg);
    }

    return error_text;
}

static void psv_debug (const char *msg, const char *value_ptr, const size_t value_size)
{
    char value_text[4*1024] = {0};
    memcpy (value_text, value_ptr, MIN (value_size, sizeof (value_text) - 1));

    fprintf (stderr, "psv_debug: %s: %s\n", msg, value_text);
}

static psv_error_t INLINE psv_read_date (const char *time_ptr, const size_t time_size, idate_t *output_ptr)
{
    const size_t time0_size = time_size + 1;

                        /* time_ptr + 0123456789 */
    const size_t date_only = sizeof ("yyyy-mm-dd");

    if (date_only == time0_size &&
        *(time_ptr + 4) == '-'  &&
        *(time_ptr + 7) == '-') {

        char *year_end, *month_end, *day_end;
        const iint_t year  = strtol (time_ptr + 0, &year_end,  10);
        const iint_t month = strtol (time_ptr + 5, &month_end, 10);
        const iint_t day   = strtol (time_ptr + 8, &day_end,   10);

        if (year_end  != time_ptr + 4 ||
            month_end != time_ptr + 7 ||
            day_end   != time_ptr + 10)
            return psv_alloc_error ("expected yyyy-mm-dd", time_ptr, time_size);

        *output_ptr = idate_from_gregorian (year, month, day, 0, 0, 0);
        return 0;
    }

                        /* time_ptr + 01234567890123456789 */
    const size_t date_time = sizeof ("yyyy-mm-ddThh:mm:ssZ");

    if (date_time == time0_size &&
        *(time_ptr +  4) == '-' &&
        *(time_ptr +  7) == '-' &&
        *(time_ptr + 10) == 'T' &&
        *(time_ptr + 13) == ':' &&
        *(time_ptr + 16) == ':' &&
        *(time_ptr + 19) == 'Z') {

        char *year_end, *month_end, *day_end, *hour_end, *minute_end, *second_end;
        const iint_t year   = strtol (time_ptr +  0, &year_end,   10);
        const iint_t month  = strtol (time_ptr +  5, &month_end,  10);
        const iint_t day    = strtol (time_ptr +  8, &day_end,    10);
        const iint_t hour   = strtol (time_ptr + 11, &hour_end,   10);
        const iint_t minute = strtol (time_ptr + 14, &minute_end, 10);
        const iint_t second = strtol (time_ptr + 17, &second_end, 10);

        if (year_end   != time_ptr +  4 ||
            month_end  != time_ptr +  7 ||
            day_end    != time_ptr + 10 ||
            hour_end   != time_ptr + 13 ||
            minute_end != time_ptr + 16 ||
            second_end != time_ptr + 19)
            return psv_alloc_error ("expected yyyy-mm-ddThh:mm:ssZ", time_ptr, time_size);

        *output_ptr = idate_from_gregorian (year, month, day, hour, minute, second);
        return 0;
    }

    return psv_alloc_error ("expected yyyy-mm-dd or yyyy-mm-ddThh:mm:ssZ but was", time_ptr, time_size);
}

static psv_error_t INLINE psv_read_json_date (imempool_t *pool, char **pp, char *pe, idate_t *output_ptr, ibool_t *done_ptr)
{
    char *p = *pp;

    if (*p++ != ':')
        return psv_alloc_error ("missing ':'",  p, pe - p);

    char *quote_ptr = memchr (p, '"', pe - p);

    if (!quote_ptr)
        return psv_alloc_error ("missing closing quote '\"'",  p, pe - p);

    char *term_ptr = quote_ptr + 1;

    if (*term_ptr != ',' && *term_ptr != '}')
        return psv_alloc_error ("terminator (',' or '}') not found", p, pe - p);

    if (*term_ptr == '}')
        *done_ptr = itrue;

    size_t date_size = quote_ptr - p;
    psv_error_t error = psv_read_date (p, date_size, output_ptr);

    if (error) return error;

    *pp = term_ptr + 1;

    return 0;
}

static psv_error_t INLINE psv_read_json_string (imempool_t *pool, char **pp, char *pe, istring_t *output_ptr, ibool_t *done_ptr)
{
    char *p = *pp;

    if (*p++ != ':')
        return psv_alloc_error ("missing ':'",  p, pe - p);

    if (*p++ != '"')
        return psv_alloc_error ("missing '\"'",  p, pe - p);

    char *quote_ptr = memchr (p, '"', pe - p);

    if (!quote_ptr)
        return psv_alloc_error ("missing closing quote '\"'",  p, pe - p);

    char *term_ptr = quote_ptr + 1;

    if (*term_ptr != ',' && *term_ptr != '}')
        return psv_alloc_error ("terminator (',' or '}') not found", p, pe - p);

    if (*term_ptr == '}')
        *done_ptr = itrue;

    size_t output_size = quote_ptr - p + 1;
    char  *output      = imempool_alloc (pool, output_size);

    output[output_size] = 0;
    memcpy (output, p, output_size - 1);

    *output_ptr = output;
    *pp         = term_ptr + 1;

    return 0;
}

static psv_error_t INLINE psv_read_json_int (imempool_t *pool, char **pp, char *pe, iint_t *output_ptr, ibool_t *done_ptr)
{
    char *p = *pp;

    if (*p++ != ':')
        return psv_alloc_error ("missing ':'",  p, pe - p);

    char *term_ptr;
    char *comma_ptr = memchr (p, ',', pe - p);

    if (comma_ptr) {
        term_ptr = comma_ptr;
    } else {
        char *brace_ptr = memchr (p, '}', pe - p);
        if (brace_ptr) {
            term_ptr  = brace_ptr;
            *done_ptr = itrue;
        } else {
            return psv_alloc_error ("terminator (',' or '}') not found", p, pe - p);
        }
    }

    char *end_ptr;
    *output_ptr = strtol (p, &end_ptr, 10);

    if (end_ptr != term_ptr)
        return psv_alloc_error ("was not an integer", p, pe - p);

    *pp = term_ptr + 1;

    return 0;
}

static psv_error_t psv_read_buffer (psv_state_t *s)
{
    psv_error_t error;

    char   *entity_cur      = s->entity_cur;
    size_t  entity_cur_size = s->entity_cur_size;

    const char  *buffer_ptr  = s->buffer_ptr;
    const size_t buffer_size = s->buffer_size;
    const char  *end_ptr     = buffer_ptr + buffer_size;
    const char  *line_ptr    = buffer_ptr;

    for (;;) {
        const size_t bytes_remaining = end_ptr - line_ptr;
        const char  *n_ptr           = memchr (line_ptr, '\n', bytes_remaining);

        if (n_ptr == 0) {
            s->entity_cur       = entity_cur;
            s->entity_cur_size  = entity_cur_size;
            s->buffer_remaining = bytes_remaining;
            return 0;
        }

        const char  *entity_ptr  = line_ptr;
        const char  *entity_end  = memchr (entity_ptr, '|', n_ptr - entity_ptr);
        const size_t entity_size = entity_end - entity_ptr;

        if (entity_end == 0)
            return psv_alloc_error ("missing |", entity_ptr, n_ptr - entity_ptr);

        const char  *attrib_ptr  = entity_end + 1;
        const char  *attrib_end  = memchr (attrib_ptr, '|', n_ptr - attrib_ptr);
        const size_t attrib_size = attrib_end - attrib_ptr;

        if (attrib_end == 0)
            return psv_alloc_error ("missing |", attrib_ptr, n_ptr - attrib_ptr);

        const char *time_ptr;
        const char *n11_ptr = n_ptr - 11;
        const char *n21_ptr = n_ptr - 21;

        if (*n11_ptr == '|') {
            time_ptr = n11_ptr + 1;
        } else if (*n21_ptr == '|') {
            time_ptr = n21_ptr + 1;
        } else {
            return psv_alloc_error ("expected |", n21_ptr, n_ptr - n21_ptr);
        }

        const char  *time_end   = n_ptr;
        const size_t time_size  = time_end - time_ptr;

        const char  *value_ptr  = attrib_end + 1;
        const char  *value_end  = time_ptr - 1;
        const size_t value_size = value_end - value_ptr;

        const bool new_entity = entity_cur_size != entity_size
                             || memcmp (entity_cur, entity_ptr, entity_size) != 0;

        if (new_entity) {
            if (entity_cur_size != 0) {
                //psv_debug ("entity", entity_cur, entity_cur_size);

                /* write output */
                psv_write_outputs (s->output_fd, entity_cur, s->fleet);
            }

            memcpy (entity_cur, entity_ptr, entity_size);
            entity_cur[entity_size] = 0;
            entity_cur_size = entity_size;
        }

        idate_t date;
        error = psv_read_date (time_ptr, time_size, &date);
        if (error) return error;

        error = psv_read_fact (s->fleet, attrib_ptr, attrib_size, value_ptr, value_size, date);
        if (error) return error;

        line_ptr = n_ptr + 1;
    }
}

void psv_snapshot (psv_config_t *cfg)
{
    int ifd = (int)cfg->input_fd;
    int ofd = (int)cfg->output_fd;

    static const size_t psv_read_error = (size_t) -1;

    char buffer_ptr[psv_buffer_size+1];
    char entity_cur[psv_buffer_size+1];
    buffer_ptr[psv_buffer_size] = '\0';
    entity_cur[psv_buffer_size] = '\0';

    ifleet_t *fleet = psv_alloc_fleet ();

    static const psv_state_t empty_state;
    psv_state_t state = empty_state;
    state.buffer_ptr  = buffer_ptr;
    state.entity_cur  = entity_cur;
    state.fleet       = fleet;
    state.output_fd   = ofd;

    size_t buffer_offset = 0;

    for (;;) {
        psv_collect_fleet(fleet);

        size_t bytes_read = read ( ifd
                                 , buffer_ptr  + buffer_offset
                                 , psv_buffer_size - buffer_offset );

        if (bytes_read == psv_read_error) {
            cfg->error = "error reading input";
            return;
        }

        if (bytes_read == 0) {
            break;
        }

        size_t bytes_avail = buffer_offset + bytes_read;
        state.buffer_size  = bytes_avail;

        psv_error_t error = psv_read_buffer (&state);

        if (error) {
            cfg->error = error;
            return;
        }

        size_t bytes_remaining = state.buffer_remaining;

        memcpy ( buffer_ptr
               , buffer_ptr + bytes_avail - bytes_remaining
               , bytes_remaining );

        buffer_offset = bytes_remaining;
    }
}

#endif