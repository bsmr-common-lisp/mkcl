/* -*- mode: c -*- */
/*
    read.d -- Read.
*/
/*
    Copyright (c) 1984, Taiichi Yuasa and Masami Hagiya.
    Copyright (c) 1990, Giuseppe Attardi.
    Copyright (c) 2001, Juan Jose Garcia Ripoll.
    Copyright (c) 2010-2012, Jean-Claude Beaudoin.

    MKCL is free software; you can redistribute it and/or
    modify it under the terms of the GNU Lesser General Public
    License as published by the Free Software Foundation; either
    version 3 of the License, or (at your option) any later version.

    See file '../../Copyright' for full details.
*/

#include <mkcl/mkcl.h>
#include <mkcl/mkcl-math.h>
#include <stdio.h>
#include <float.h>
#include <string.h>
#include <stdlib.h>
#include <mkcl/internal.h>
#include <mkcl/mkcl-inl.h>
#include <mkcl/bytecode.h>


#ifdef MKCL_WINDOWS
#define READTABLE_LOCK(r) EnterCriticalSection(&(r)->readtable.lock)
#define READTABLE_UNLOCK(r) LeaveCriticalSection(&(r)->readtable.lock)
#else
#define READTABLE_LOCK(r)				\
  if (pthread_mutex_lock(&(r)->readtable.lock))		\
    mkcl_lose(env, "Failed in READTABLE_LOCK()")
#define READTABLE_UNLOCK(r)				\
  if (pthread_mutex_unlock(&(r)->readtable.lock))	\
    mkcl_lose(env, "Failed in READTABLE_UNLOCK()")
#endif

static mkcl_object dispatch_macro_character(MKCL, mkcl_object table, mkcl_object strm, int c);

#define read_suppress(env) (mkcl_symbol_value(env, @'*read-suppress*') != mk_cl_Cnil)

# define TOKEN_STRING_DIM(s) ((s)->string.dim)
# define TOKEN_STRING_FILLP(s) ((s)->string.fillp)
# define TOKEN_STRING_CHAR(s,n) ((s)->string.self[n])
# define TOKEN_STRING_CHAR_SET(s,n,c) (s)->string.self[n]=(c)
# define TOKEN_STRING_CHAR_CMP(s,n,c) ((s)->string.self[n]==(c))

#define MKCL_READ_ONLY_TOKEN 1
#define MKCL_READ_RETURN_IGNORABLE 3


mkcl_object
mk_si_get_buffer_string(MKCL)
{
  mkcl_object pool = env->string_pool;
  mkcl_object output;

  mkcl_call_stack_check(env);
  if (pool == mk_cl_Cnil) {
    output = mkcl_alloc_adjustable_character_string(env, MKCL_BUFFER_STRING_SIZE);
  } else {
    output = MKCL_CAR(pool);
    env->string_pool = MKCL_CDR(pool);
  }
  TOKEN_STRING_FILLP(output) = 0;
  @(return output);
}

mkcl_object
mk_si_put_buffer_string(MKCL, mkcl_object string)
{
  mkcl_call_stack_check(env);
  if (string != mk_cl_Cnil) {
    mkcl_object pool = env->string_pool;
    mkcl_index l = 0;
    if (pool != mk_cl_Cnil) {
      /* We store the size of the pool in the string index */
      l = TOKEN_STRING_FILLP(MKCL_CONS_CAR(pool));
    }
    if (l < MKCL_MAX_STRING_POOL_SIZE) {
      TOKEN_STRING_FILLP(string) = l+1;
      env->string_pool = MKCL_CONS(env, string, pool);
    }
  }
  @(return);
}

static void extra_argument (MKCL, int c, mkcl_object stream, mkcl_object d);
static mkcl_object patch_sharp(MKCL, mkcl_object x);
static mkcl_object do_read_delimited_list(MKCL, int d, mkcl_object strm, bool proper_list);

mkcl_object
mkcl_read_object_non_recursive(MKCL, mkcl_object in)
{
  mkcl_object x;
  
  mkcl_bds_bind(env, @'si::*sharp-eq-context*', mk_cl_Cnil);
  mkcl_bds_bind(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(0));
  x = mkcl_read_object(env, in);
  if (!mkcl_Null(MKCL_SYM_VAL(env, @'si::*sharp-eq-context*')))
    x = patch_sharp(env, x);
  
  mkcl_bds_unwind_n(env, 2);
  return x;
}

/*
 * This routine inverts the case of the characters in the buffer which
 * were not escaped. ESCAPE_LIST is a list of intevals of characters
 * that were escaped, as in ({(low-limit . high-limit)}*). The list
 * goes from the last interval to the first one, in reverse order,
 * and thus we run the buffer from the end to the beginning.
 */
static void
invert_buffer_case(mkcl_object x, mkcl_object escape_list, int sign)
{
  mkcl_word high_limit, low_limit;
  mkcl_word i = TOKEN_STRING_FILLP(x);
  do {
    if (escape_list != mk_cl_Cnil) {
      mkcl_object escape_interval = MKCL_CAR(escape_list);
      high_limit = mkcl_fixnum_to_word(MKCL_CAR(escape_interval));
      low_limit = mkcl_fixnum_to_word(MKCL_CDR(escape_interval));
      escape_list = MKCL_CDR(escape_list);
    } else {
      high_limit = low_limit = -1;
    }
    for (; i > high_limit; i--) {
      /* The character is not escaped */
      int c = TOKEN_STRING_CHAR(x,i);
      if (mkcl_upper_case_p(c) && (sign < 0)) {
	c = mkcl_char_downcase(c);
      } else if (mkcl_lower_case_p(c) && (sign > 0)) {
	c = mkcl_char_upcase(c);
      }
      TOKEN_STRING_CHAR_SET(x,i,c);
    }
    for (; i > low_limit; i--) {
      /* The character is within an escaped interval */
      ;
    }
  } while (i >= 0);
}

static mkcl_object
mkcl_read_object_with_delimiter(MKCL, mkcl_object in, mkcl_character delimiter, int flags, enum mkcl_chattrib a)
{
  mkcl_object x, token;
  mkcl_character c;
  unsigned int base;
  mkcl_object p;
  mkcl_index length;
  int colon, intern_flag;
  bool external_symbol;
  mkcl_object rtbl = mkcl_current_readtable(env);
  enum mkcl_readtable_case read_case = rtbl->readtable.read_case;
  mkcl_object escape_list; /* intervals of escaped characters */
  mkcl_word upcase; /* # uppercase characters - # downcase characters */
  mkcl_word count; /* number of unescaped characters */
  bool suppress = read_suppress(env);
  if (a != mkcl_cat_constituent) {
    c = 0;
    goto LOOP;
  }
 BEGIN:
  do {
    c = mkcl_read_char(env, in);
    if (c == delimiter) {
      env->nvalues = 0;
      return MKCL_OBJNULL;
    }
    if (c == EOF)
      mkcl_FEend_of_file(env, in);
    a = mkcl_readtable_get(env, rtbl, c, &x);
  } while (a == mkcl_cat_whitespace);
  if ((a == mkcl_cat_terminating || a == mkcl_cat_non_terminating)
      && (flags != MKCL_READ_ONLY_TOKEN)) {
    mkcl_object o;
    if (mkcl_type_of(x) == mkcl_t_hashtable) {
      o = dispatch_macro_character(env, x, in, c);
    } else {
      o = mkcl_funcall2(env, x, in, MKCL_CODE_CHAR(c));
    }
    if (env->nvalues == 0) {
      if (flags == MKCL_READ_RETURN_IGNORABLE)
	return mk_cl_Cnil;
      goto BEGIN;
    }
    if (env->nvalues > 1) {
      mkcl_FEerror(env, "The readmacro ~S returned ~D values.", 2, x, MKCL_MAKE_FIXNUM(env->nvalues));
    }
    return o;
  }
 LOOP:
  p = escape_list = mk_cl_Cnil;
  upcase = count = length = 0;
  external_symbol = false; colon = 0;
  token = mk_si_get_buffer_string(env);
  for (;;)
    {
      if (c == ':' && (flags != MKCL_READ_ONLY_TOKEN) && a == mkcl_cat_constituent) {
        colon++;
        goto NEXT;
      }
      if (colon > 2) {
        while (colon--) {
          mkcl_string_push_extend(env, token, ':');
          length++;
        }
      } else if (colon) {
        external_symbol = (colon == 1);
        TOKEN_STRING_CHAR_SET(token,length,'\0');
        /* If the readtable case was :INVERT and all non-escaped characters
         * had the same case, we revert their case. */
        if (read_case == mkcl_case_invert) {
          if (upcase == count) {
            invert_buffer_case(token, escape_list, -1);
          } else if (upcase == -count) {
            invert_buffer_case(token, escape_list, +1);
          }
        }
        if (length == 0) {
          p = mkcl_core.keyword_package;
          external_symbol = 0;
        } else {
#if 0
          p = mkcl_find_package_nolock(env, token); /* Why is this "nolock"? JCB */
#else
          p = mk_cl_find_package(env, token);
#endif
        }
        if (mkcl_Null(p) && !suppress) {
          /* When loading binary files, we sometimes must create
             symbols whose package has not yet been made. We
             allow it, but later on in mkcl_read_VV we make sure that
             all referenced packages have been properly built.
          */
          mkcl_object name = mk_cl_copy_seq(env, token);
          volatile bool list_locked = false;

          MKCL_UNWIND_PROTECT_BEGIN(env) {
            MKCL_LIBC_NO_INTR(env, (MKCL_PACKAGE_LIST_LOCK(), list_locked = true));
            if (mkcl_core.packages_to_be_created == MKCL_OBJNULL
                || mkcl_Null(MKCL_SYM_VAL(env, @'si::+reading-fasl-file+')))
              p = mk_cl_Cnil; /* we confirm. */
            else if (!mkcl_Null(p = mkcl_assoc(env, name, mkcl_core.packages_to_be_created)))
              p = MKCL_CDR(p);
            else
              {
                p = _mkcl_alloc_package(env, name);
                mkcl_core.packages_to_be_created = mk_cl_acons(env, name, p, mkcl_core.packages_to_be_created);
              }
          } MKCL_UNWIND_PROTECT_EXIT {
            if (list_locked) MKCL_PACKAGE_LIST_UNLOCK();
          } MKCL_UNWIND_PROTECT_END;
	
          if (mkcl_Null(p))
            mkcl_FEerror(env, "There is no package with the name ~A.", 1, name);	
        }
        TOKEN_STRING_FILLP(token) = length = 0;
        upcase = count = colon = 0;
        escape_list = mk_cl_Cnil;
      }
      if (a == mkcl_cat_single_escape) {
        c = mkcl_read_char_noeof(env, in);
        /* a = mkcl_cat_constituent; */ /* This value is said to be unused. */
        if (read_case == mkcl_case_invert) {
          escape_list = MKCL_CONS(env,
                                  MKCL_CONS(env, MKCL_MAKE_FIXNUM(length), MKCL_MAKE_FIXNUM(length)),
                                  escape_list);
        } else {
          escape_list = mk_cl_Ct;
        }
        mkcl_string_push_extend(env, token, c);
        length++;
        goto NEXT;
      }
      if (a == mkcl_cat_multiple_escape) {
        mkcl_index begin = length;
        for (;;) {
          c = mkcl_read_char_noeof(env, in);
          a = mkcl_readtable_get(env, rtbl, c, NULL);
          if (a == mkcl_cat_single_escape) {
            c = mkcl_read_char_noeof(env, in);
            /* a = mkcl_cat_constituent; */ /* This value is said to be unused. */
          } else if (a == mkcl_cat_multiple_escape)
            break;
          mkcl_string_push_extend(env, token, c);
          length++;
        }
        if (read_case == mkcl_case_invert) {
          escape_list = MKCL_CONS(env, MKCL_CONS(env, MKCL_MAKE_FIXNUM(begin),
                                                 MKCL_MAKE_FIXNUM(length-1)),
                                  escape_list);
        } else {
          escape_list = mk_cl_Ct;
        }
        goto NEXT;
      }
      if (a == mkcl_cat_whitespace || a == mkcl_cat_terminating) {
        mkcl_unread_char(env, c, in);
        break;
      }
      if (mkcl_invalid_constituent_character_p(c)) {
        mkcl_FEreader_error(env, "While reading a lisp token, found invalid constituent character #\\~:C", in, 1, MKCL_CODE_CHAR(c));
      }
      if (read_case != mkcl_case_preserve) {
        if (mkcl_upper_case_p(c)) {
          upcase++;
          count++;
          if (read_case == mkcl_case_downcase)
            c = mkcl_char_downcase(c);
        } else if (mkcl_lower_case_p(c)) {
          upcase--;
          count++;
          if (read_case == mkcl_case_upcase)
            c = mkcl_char_upcase(c);
        }
      }
      mkcl_string_push_extend(env, token, c);
      length++;
    NEXT:
      c = mkcl_read_char(env, in);
      if (c == EOF)
        break;
      a = mkcl_readtable_get(env, rtbl, c, NULL);
    }

  if (suppress) {
    x = mk_cl_Cnil;
    goto OUTPUT;
  }

  /* If there are some escaped characters, it must be a symbol */
  if ((flags == MKCL_READ_ONLY_TOKEN) || p != mk_cl_Cnil
      || escape_list != mk_cl_Cnil || length == 0)
    goto SYMBOL;

  {
    mkcl_index i;
    /* The case in which the buffer is full of dots has to be especial cased */
    if (length == 1 && TOKEN_STRING_CHAR_CMP(token,0,'.')) {
      x = @'si::.';
      goto OUTPUT;
    } else {
      for (i = 0;  i < length;  i++)
	if (!TOKEN_STRING_CHAR_CMP(token,i,'.'))
	  goto MAYBE_NUMBER;
      mkcl_FEreader_error(env, "While reading a lisp token, dots appeared illegally.", in, 0);
    }

  MAYBE_NUMBER:
    /* Here we try to parse a number from the content of the buffer */
    base = mkcl_current_read_base(env);
    if ((base <= 10) && mkcl_alpha_char_p(TOKEN_STRING_CHAR(token,0)))
      goto SYMBOL;
    x = mkcl_parse_number(env, token, 0, TOKEN_STRING_FILLP(token), &i, base);
    if (x == mk_cl_Cnil)
      mkcl_FEreader_error(env, "Syntax error when reading number.~%Offending string: ~S.",
			  in, 1, token);
    if (x != MKCL_OBJNULL && length == i)
      goto OUTPUT;
  }

 SYMBOL:
  /*TOKEN_STRING_CHAR_SET(token,length,'\0');*/
  /* If the readtable case was :INVERT and all non-escaped characters
   * had the same case, we revert their case. */
  if (read_case == mkcl_case_invert) {
    if (upcase == count) {
      invert_buffer_case(token, escape_list, -1);
    } else if (upcase == -count) {
      invert_buffer_case(token, escape_list, +1);
    }
  }
  if (flags == MKCL_READ_ONLY_TOKEN) {
    env->nvalues = 1;
    return token;
  } else if (external_symbol) {
    x = mkcl_find_symbol(env, token, p, &intern_flag);
    if (intern_flag != MKCL_SYMBOL_IS_EXTERNAL) {
      mkcl_FEerror(env, "Cannot find the external symbol ~A in ~S.", 2, mk_cl_copy_seq(env, token), p);
    }
  } else {
    if (p == mk_cl_Cnil) {
      p = mkcl_current_package(env);
    }
    /* INV: mk_cl_make_symbol() copies the string */
    x = mkcl_intern(env, token, p, &intern_flag);
  }
 OUTPUT:
  mk_si_put_buffer_string(env, token);
  env->nvalues = 1;
  return x;
}

/*
	mkcl_read_object(in) reads an object from stream in.
	This routine corresponds to COMMON Lisp function READ.
*/
mkcl_object
mkcl_read_object(MKCL, mkcl_object in)
{
  return mkcl_read_object_with_delimiter(env, in, EOF, 0, mkcl_cat_constituent);
}

mkcl_object
mk_si_read_object_or_ignore(MKCL, mkcl_object in, mkcl_object eof)
{
  mkcl_object x;

  mkcl_call_stack_check(env);
  mkcl_bds_bind(env, @'si::*sharp-eq-context*', mk_cl_Cnil);
  mkcl_bds_bind(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(0));
  x = mkcl_read_object_with_delimiter(env, in, EOF, MKCL_READ_RETURN_IGNORABLE, 
				      mkcl_cat_constituent);
  if (x == MKCL_OBJNULL) {
    MKCL_NVALUES = 1;
    x = eof;
  } else if (env->nvalues != 0) {
    if (!mkcl_Null(MKCL_SYM_VAL(env, @'si::*sharp-eq-context*')))
      x = patch_sharp(env, x);
  }
  mkcl_bds_unwind_n(env, 2);
  return x;
}


#define exponent_charp(c) \
  ((c == 'e') || (c == 'E') || (c == 'f') || (c == 'F')	  \
   || (c == 's') || (c == 'S') || (c == 'd') || (c == 'D')	\
   || (c == 'l') || (c == 'L'))

static mkcl_object
expt10(MKCL, mkcl_index expt)
{
  mkcl_object accum = _mkcl_big_register0();
  mkcl_object factor = _mkcl_big_register1();
  _mkcl_big_set_ui(accum, 1);
  _mkcl_big_set_ui(factor, 10);
  for (; expt; expt >>= 1) {
    if (expt & 1) {
      _mkcl_big_mul(accum, accum, factor);
    }
    _mkcl_big_mul(factor, factor, factor);
  }
  _mkcl_big_register_free(env, factor);
  return _mkcl_big_register_normalize(env, accum);
}

static mkcl_object
infinity(MKCL, mkcl_index exp_char, int sign)
{
  mkcl_object var;
  switch (exp_char) {
  case 'e': case 'E':
    return infinity(env, mkcl_current_read_default_float_format(env), sign);
  case 's':  case 'S':
  case 'f':  case 'F':
    var = (sign<0)?
      @'mkcl::single-float-negative-infinity' :
    @'mkcl::single-float-positive-infinity';
    break;
  case 'l':  case 'L':
#ifdef MKCL_LONG_FLOAT
    var = (sign<0)?
      @'mkcl::long-float-negative-infinity' :
    @'mkcl::long-float-positive-infinity';
    break;
#endif
  case 'd':  case 'D':
    var = (sign<0)?
      @'mkcl::double-float-negative-infinity' :
    @'mkcl::double-float-positive-infinity';
    break;
  default:
    return MKCL_OBJNULL;
  }
  return mkcl_symbol_value(env, var);
}

static mkcl_object
make_float(MKCL, mkcl_object num, mkcl_object exp, mkcl_index exp_char, int sign)
{
  mkcl_object output = MKCL_OBJNULL;
  bool fe_inexact_on = FALSE;
  mkcl_object read_exactly_p = mkcl_symbol_value(env, @'si::*read-float-exactly*'); 

  if (mkcl_Null(read_exactly_p))
    {
      fe_inexact_on = FE_INEXACT & fegetexcept();
      if (fe_inexact_on)
	{
	  /* printf("\nmake_float: turning off FE_INEXACT!\n"); fflush(NULL); */
	  fedisableexcept(FE_INEXACT);
	}
    }
  else
    { printf("\nmake_float told to read exactly!\n"); fflush(NULL); }


  if (!MKCL_FIXNUMP(exp)) {
    output = infinity(env, exp_char, sign);
  } else {
    mkcl_word fix_exp = mkcl_fixnum_to_word(exp);
    if (fix_exp > 0) {
      num = mkcl_times(env, num, expt10(env, fix_exp));
    } else if (fix_exp < 0) {
      num = mkcl_divide(env, num, expt10(env, -fix_exp));
    }
  AGAIN:
    switch (exp_char) {
    case 'e': case 'E':
      exp_char = mkcl_current_read_default_float_format(env);
      goto AGAIN;
    case 's':  case 'S':
    case 'f':  case 'F':
      output = mkcl_make_singlefloat(env, sign * mkcl_to_float(env, num));
      /* return mkcl_make_singlefloat(env, sign * mkcl_to_double(env, num)); */
      break;
    case 'l':  case 'L':
#ifdef MKCL_LONG_FLOAT
      output = mkcl_make_longfloat(env, sign * mkcl_to_long_double(env, num));
      break;
#endif
    case 'd':  case 'D':
      output = mkcl_make_doublefloat(env, sign * mkcl_to_double(env, num));
      break;
    default:
      output = MKCL_OBJNULL;
      break;
    }
  }
  feclearexcept(FE_INEXACT); /* Clear leftovers from casting. */ /* should it be FE_ALL_EXCEPT? JCB */
  if (fe_inexact_on)
    {
      /* printf("\nmake_float: turning on FE_INEXACT!\n"); fflush(NULL); */
      feenableexcept(FE_INEXACT);
    }
  return output;
}

/*
	mkcl_parse_number(str, start, end, ep, radix) parses C string str
	up to (but not including) str[end]
	using radix as the radix for the rational number.
	(For floating numbers, the radix is ignored and replaced with 10)
	When parsing succeeds,
	the index of the next character is assigned to *ep,
	and the number is returned as a lisp data object.
	If not, MKCL_OBJNULL is returned.
*/
mkcl_object
mkcl_parse_number(MKCL, mkcl_object str, mkcl_index start, mkcl_index end,
		  mkcl_index *ep, unsigned int radix)
{
  int sign = -1, d;
  mkcl_index c, i, decimal = end;
  mkcl_object numerator = _mkcl_big_register0(); /* "numerator" must always be a bignum, otherwise SIGSEGV! */
  if (end <= start || radix > 36) {
    *ep = start;
    return MKCL_OBJNULL;
  }
 AGAIN:
  _mkcl_big_set_ui(numerator, 0);
  c = mkcl_char(env, str, i = start);
  sign = 1;
  if (c == '+') {
    if (++i == end) goto NOT_A_NUMBER;
    c = mkcl_char(env, str, i);
  } else if (c == '-') {
    sign = -1;
    if (++i == end) goto NOT_A_NUMBER;
    c = mkcl_char(env, str, i);
  }
  if (c == '/') {
    goto NOT_A_NUMBER;
  }
  for (; i < end; i++) {
    c = mkcl_char(env, str, i);
    if (c == '/') {
      mkcl_object den;
      if (sign < 0) _mkcl_big_complement(numerator, numerator);

      /* This "normalize" must be done before the call to mkcl_parse_integer, otherwise SIGFPE! */
      mkcl_object num = _mkcl_big_register_normalize(env, numerator);

      c = mkcl_char(env, str, ++i);
      if (mkcl_digitp(c, radix) < 0)
	goto NOT_A_NUMBER;
      den = mkcl_parse_integer(env, str, i, end, ep, radix);
      if (den == MKCL_OBJNULL || (*ep < end)) {
	return MKCL_OBJNULL;
      } else if (den == MKCL_MAKE_FIXNUM(0)) {
	return mk_cl_Cnil;
      } else {
	return mkcl_make_ratio(env, num, den);
      }
    } else if (c == '.') {
      if (decimal <= i) {
	goto NOT_A_NUMBER;
      }
      if (radix != 10) {
	radix = 10;
	goto AGAIN;
      }
      /* For a number xxxx.1234...nEyyy
       * we have stored in numerator the number xxxx1234...n and
       * will get in the exponent yyy. What we do is to simply
       * shift the exponent by -n. */
      decimal = i+1;
    } else if ((d = mkcl_digitp(c, radix)) >= 0) {
      _mkcl_big_mul_ui(numerator, numerator, radix);
      _mkcl_big_add_ui(numerator, numerator, d);
    } else if (exponent_charp(c)) {
      mkcl_object exp, decimals;
      if (radix != 10) {
	radix = 10;
	goto AGAIN;
      }
      /* This "normalize" must be done before the call to mkcl_parse_integer, otherwise SIGFPE! */
      mkcl_object num = _mkcl_big_register_normalize(env, numerator);
      decimals = (decimal < i) ?
	MKCL_MAKE_FIXNUM(decimal - i):
	MKCL_MAKE_FIXNUM(0);
      exp = mkcl_parse_integer(env, str, ++i, end, ep, 10);
      if (exp == MKCL_OBJNULL || (*ep < end))
	return MKCL_OBJNULL;
      return make_float(env, num, mkcl_plus(env, decimals, exp), c, sign);
    } else if (radix != 10) {
      _mkcl_big_register_free(env, numerator);
      mkcl_object number = mkcl_parse_number(env, str, start, end, ep, 10);
      if (number != MKCL_OBJNULL) {
	if (mkcl_floatp(env, number))
	  return number;
	if (MKCL_FIXNUMP(number) || MKCL_BIGNUMP(number)) {
	  i = *ep;
	  if (i > start && mkcl_char(env, str, i-1) == '.')
	    return number;
	}
      }
      return MKCL_OBJNULL;
    } else {
    NOT_A_NUMBER:
      *ep = i;
      _mkcl_big_register_free(env, numerator);
      return MKCL_OBJNULL;
    }
  }
  /* If we have reached the end without decimals (for instance
   * 1., 2, 13., etc) we return an integer */
  *ep = i;
  if (decimal < i) {
    return make_float(env, _mkcl_big_register_normalize(env, numerator), MKCL_MAKE_FIXNUM(decimal - i), 'e', sign);
  } else {
    if (sign < 0) _mkcl_big_complement(numerator, numerator);
    return _mkcl_big_register_normalize(env, numerator);
  }
}


#define basep(d)	(d <= 36)

mkcl_object
mkcl_parse_integer(MKCL, mkcl_object str, mkcl_index start, mkcl_index end,
		   mkcl_index *ep, unsigned int radix)
{
  int sign, d;
  mkcl_object integer_part, output;
  mkcl_index i = 0, c;

  if (start >= end || !basep(radix)) {
    *ep = i;
    return MKCL_OBJNULL;
  }
  sign = 1;
  c = mkcl_char(env, str, start);
  if (c == '+') {
    start++;
  } else if (c == '-') {
    sign = -1;
    start++;
  }
  integer_part = _mkcl_big_register0();
  _mkcl_big_set_ui(integer_part, 0);
  for (i = start; i < end; i++) {
    c = mkcl_char(env, str, i);
    d = mkcl_digitp(c, radix);
    if (d < 0) {
      break;
    }
    _mkcl_big_mul_ui(integer_part, integer_part, radix);
    _mkcl_big_add_ui(integer_part, integer_part, d);
  }
  if (sign < 0) {
    _mkcl_big_complement(integer_part, integer_part);
  }
  output = _mkcl_big_register_normalize(env, integer_part);
  *ep = i;
  return (i == start)? MKCL_OBJNULL : output;
}

static mkcl_object
right_parenthesis_reader(MKCL, mkcl_object in, mkcl_object character)
{
  mkcl_FEreader_error(env, "Unmatched right parenthesis, #\\)", in, 0);
}

static mkcl_object
left_parenthesis_reader(MKCL, mkcl_object in, mkcl_object character)
{
  const char c = ')';
  @(return do_read_delimited_list(env, c, in, 0));
}

/*
 * BACKQUOTE READER
 */

static
mkcl_object comma_reader(MKCL, mkcl_object in, mkcl_object c)
{
  mkcl_object x, y;
  mkcl_word backq_level = mkcl_fixnum_to_word(MKCL_SYM_VAL(env, @'si::*backq-level*'));

  if (backq_level <= 0)
    mkcl_FEreader_error(env, "A comma has appeared out of a backquote.", in, 0);
  /* Read character & complain at EOF */
  c = mk_cl_peek_char(env, 2,mk_cl_Cnil,in);
  if (c == MKCL_CODE_CHAR('@@')) {
    x = @'si::unquote-splice';
    mkcl_read_char(env, in);
  } else if (c == MKCL_CODE_CHAR('.')) {
    x = @'si::unquote-nsplice';
    mkcl_read_char(env, in);
  } else {
    x = @'si::unquote';
  }
  MKCL_SETQ(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(backq_level-1));
  y = mkcl_read_object(env, in);
  MKCL_SETQ(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(backq_level));
  return mk_cl_list(env, 2, x, y);
}

static
mkcl_object backquote_reader(MKCL, mkcl_object in, mkcl_object c)
{
  mkcl_word backq_level = mkcl_fixnum_to_word(MKCL_SYM_VAL(env, @'si::*backq-level*'));
  MKCL_SETQ(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(backq_level+1));
  in = mkcl_read_object(env, in);
  MKCL_SETQ(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(backq_level));
#if 0
  @(return mk_cl_macroexpand_1(env, 2, mk_cl_list(env, 2, @'si::quasiquote', in), mk_cl_Cnil));
#else
  @(return mk_cl_list(env, 2,@'si::quasiquote',in));
#endif
}

/*
	read_constituent(in) reads a sequence of constituent characters from
	stream in and places it in token.  As a help, it returns TRUE
	or FALSE depending on the value of *READ-SUPPRESS*.
*/
static mkcl_object
read_constituent(MKCL, mkcl_object in)
{
  int store = !read_suppress(env);
  mkcl_object rtbl = mkcl_current_readtable(env);
  bool not_first = 0;
  mkcl_object token = mk_si_get_buffer_string(env);
  do {
    mkcl_character c = mkcl_read_char(env, in);
    enum mkcl_chattrib c_cat;
    if (c == EOF) {
      break;
    }
    c_cat = mkcl_readtable_get(env, rtbl, c, NULL);
    if (c_cat == mkcl_cat_constituent ||
	((c_cat == mkcl_cat_non_terminating) && not_first))
      {
	if (store) {
	  mkcl_string_push_extend(env, token, c);
	}
      } else {
      mkcl_unread_char(env, c, in);
      break;
    }
    not_first = 1;
  } while(1);
  return (read_suppress(env))? mk_cl_Cnil : token;
}

static mkcl_object
double_quote_reader(MKCL, mkcl_object in, mkcl_object c)
{
  int delim = MKCL_CHAR_CODE(c);
  mkcl_object rtbl = mkcl_current_readtable(env);
  mkcl_object token = mk_si_get_buffer_string(env);
  mkcl_object output;
  for (;;) {
    int c = mkcl_read_char_noeof(env, in);
    if (c == delim)
      break;
    else if (mkcl_readtable_get(env, rtbl, c, NULL) == mkcl_cat_single_escape)
      c = mkcl_read_char_noeof(env, in);
    mkcl_string_push_extend(env, token, c);
  }
  if (mkcl_fits_in_base_string(env, token))
    output = mkcl_coerce_to_base_string(env, token);
  else
    output = mk_cl_copy_seq(env, token);
  mk_si_put_buffer_string(env, token);
  @(return output);
}

static mkcl_object
dispatch_reader_fun(MKCL, mkcl_object in, mkcl_object dc)
{
  mkcl_object readtable = mkcl_current_readtable(env);
  mkcl_object dispatch_table;
  int c = mkcl_char_code(env, dc);
  mkcl_readtable_get(env, readtable, c, &dispatch_table);
  if (mkcl_type_of(dispatch_table) != mkcl_t_hashtable)
    mkcl_FEreader_error(env, "~C is not a dispatching macro character", in, 1, dc);
  return dispatch_macro_character(env, dispatch_table, in, c);
}

static mkcl_object
dispatch_macro_character(MKCL, mkcl_object table, mkcl_object in, int c)
{
  mkcl_object arg;
  int d;
  c = mkcl_read_char_noeof(env, in);
  d = mkcl_digitp(c, 10);
  if (d >= 0) {
    mkcl_word i = 0;
    do {
      i = 10*i + d;
      c = mkcl_read_char_noeof(env, in);
      d = mkcl_digitp(c, 10);
    } while (d >= 0);
    arg = MKCL_MAKE_FIXNUM(i);
  } else {
    arg = mk_cl_Cnil;
  }
  {
    mkcl_object dc = MKCL_CODE_CHAR(c);
    mkcl_object fun = mkcl_gethash_safe(env, dc, table, mk_cl_Cnil);
    if (mkcl_Null(fun)) {
      mkcl_FEreader_error(env, "No dispatch function defined for character ~S",
			  in, 1, dc);
    }
    return mkcl_funcall3(env, fun, in, dc, arg);
  }
}

static mkcl_object
single_quote_reader(MKCL, mkcl_object in, mkcl_object c)
{
  c = mkcl_read_object(env, in);
  if (c == MKCL_OBJNULL)
    mkcl_FEend_of_file(env, in);
  @(return mk_cl_list(env, 2, @'quote', c));
}

static mkcl_object
void_reader(MKCL, mkcl_object in, mkcl_object c)
{
  /*  no result  */
  @(return);
}

static mkcl_object
semicolon_reader(MKCL, mkcl_object in, mkcl_object c)
{
  mkcl_character auxc;

  do
    auxc = mkcl_read_char(env, in);
  while (auxc != '\n' && auxc != EOF);
  /*  no result  */
  @(return);
}

/*
	sharpmacro routines
*/

static mkcl_object
sharp_C_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object x, real, imag;

  if (d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, 'C', in, d);
  x = mkcl_read_object(env, in);
  if (x == MKCL_OBJNULL)
    mkcl_FEend_of_file(env, in);
  if (read_suppress(env))
    @(return mk_cl_Cnil);
  if (mkcl_Null(x) || mkcl_type_of(x) != mkcl_t_cons || mkcl_length(env, x) != 2)
    mkcl_FEreader_error(env, "Reader macro #C should be followed by a list",
		   in, 0);
  real = MKCL_CAR(x);
  imag = MKCL_CADR(x);
  /* INV: mkcl_make_complex() checks its types. When reading circular
     structures, we cannot check the types of the elements, and we
     must build the complex number by hand. */
  if ((MKCL_CONSP(real) || MKCL_CONSP(imag)) &&
      !mkcl_Null(MKCL_SYM_VAL(env, @'si::*sharp-eq-context*')))
    {
      x = mkcl_alloc_raw_complex(env);
      x->_complex.real = real;
      x->_complex.imag = imag;
    } else {
    x = mkcl_make_complex(env, real, imag);
  }
  @(return x);
}

static mkcl_object
sharp_backslash_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object token;
  if (d != mk_cl_Cnil && !read_suppress(env))
    if (!MKCL_FIXNUMP(d) ||
	mkcl_fixnum_to_word(d) != 0)
      mkcl_FEreader_error(env, "~S is an illegal CHAR-FONT.", in, 1, d);
  /*  assuming that CHAR-FONT-LIMIT is 1  */
  mkcl_bds_bind(env, @'*readtable*', mkcl_core.standard_readtable);
  token = mkcl_read_object_with_delimiter(env, in, EOF, MKCL_READ_ONLY_TOKEN,
					  mkcl_cat_single_escape);
  mkcl_bds_unwind1(env);
  if (token == mk_cl_Cnil) {
    c = mk_cl_Cnil;
  } else if (TOKEN_STRING_FILLP(token) == 1) {
    c = MKCL_CODE_CHAR(TOKEN_STRING_CHAR(token,0));
  } else if (TOKEN_STRING_FILLP(token) == 2 && TOKEN_STRING_CHAR_CMP(token,0,'^')) {
    /*	#\^x	*/
    c = MKCL_CODE_CHAR(TOKEN_STRING_CHAR(token,1) & 037);
  } else {
    mkcl_object nc = mk_cl_name_char(env, token);
    if (mkcl_Null(nc)) {
      mkcl_FEreader_error(env, "~S is an invalid character name.", in, 1, token);
    }
    c = nc;
  }
  mk_si_put_buffer_string(env, token);
  @(return c);
}

static mkcl_object
sharp_single_quote_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  bool suppress = read_suppress(env);
  if(d != mk_cl_Cnil && !suppress)
    extra_argument(env, '\'', in, d);
  c = mkcl_read_object(env, in);
  if (c == MKCL_OBJNULL) {
    mkcl_FEend_of_file(env, in);
  } else if (suppress) {
    c = mk_cl_Cnil;
  } else {
    c = mk_cl_list(env, 2, @'function', c);
  }
  @(return c);
}


#define	QUOTE	1
#define	EVAL	2
#define	LIST	3
#define	LISTX	4
#define	APPEND	5
#define	NCONC	6


/*
 *----------------------------------------------------------------------
 *	Stack of unknown size
 *----------------------------------------------------------------------
 */

static mkcl_object
sharp_left_parenthesis_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object v;

  if (mkcl_fixnum_to_word(MKCL_SYM_VAL(env, @'si::*backq-level*')) > 0) {
    /* First case: ther might be unquoted elements in the vector.
     * Then we just create a form that generates the vector.
     */
    mkcl_object x = do_read_delimited_list(env, ')', in, 1);
    mkcl_index a = _mkcl_backq_car(env, &x);
    if (a == APPEND || a == NCONC)
      mkcl_FEreader_error(env, "A ,@ or ,. appeared in an illegal position.",
		     in, 0);
    if (a == QUOTE) {
      v = mkcl_funcall3(env, @+'make-array', mk_cl_list(env, 1, mk_cl_length(env, x)), @':initial-contents', x);
    } else {
      v = mk_cl_list(env, 2, @'si::unquote', 
		     mk_cl_list(env, 3, @'apply',
				mk_cl_list(env, 2, @'quote', @'vector'), x));
    }
  } else if (read_suppress(env)) {
    /* Second case: *read-suppress* = t, we ignore the data */
    do_read_delimited_list(env, ')', in, 1);
    v = mk_cl_Cnil;
  } else if (mkcl_Null(d)) {
    /* Third case: no dimension provided. Read a list and
       coerce it to vector. */
    mkcl_object x = do_read_delimited_list(env, ')', in, 1);
    v = mkcl_funcall3(env, @+'make-array', mk_cl_list(env, 1, mk_cl_length(env, x)), @':initial-contents', x);
  } else {
    /* Finally: Both dimension and data are provided. The
       amount of data cannot exceed the length, but it may
       be smaller, and in that case...*/
    mkcl_index dim = mkcl_fixnum_in_range(env, @'make-array',"size",d,0,MKCL_ADIMLIM);
    mkcl_object last;
    mkcl_index i;
    v = mkcl_alloc_simple_vector(env, dim, mkcl_aet_object);
    for (i = 0, last = mk_cl_Cnil;; i++) {
      mkcl_object aux = mkcl_read_object_with_delimiter(env, in, ')', 0, mkcl_cat_constituent);
      if (aux == MKCL_OBJNULL)
	break;
      if (i >= dim) {
	mkcl_FEreader_error(env, "Vector larger than specified length, ~D.", in, 1, d);
      }
      mkcl_vset_index(env, v, i, last = aux);
    }
    /* ... we fill the vector with the last element read (or NIL). */
    for (; i < dim; i++) {
      mkcl_vset_index(env, v, i, last);
    }
  }
  @(return v);
}

static mkcl_object
sharp_asterisk_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_index sp = MKCL_TEMP_STACK_INDEX(env);
  mkcl_object last = mk_cl_Cnil, elt, x;
  mkcl_index dim, dimcount, i;
  mkcl_object rtbl = mkcl_current_readtable(env);
  enum mkcl_chattrib a;

  if (read_suppress(env)) {
    read_constituent(env, in);
    @(return mk_cl_Cnil);
  }
  for (dimcount = 0 ;; dimcount++) {
    mkcl_character x = mkcl_read_char(env, in);
    if (x == EOF)
      break;
    a = mkcl_readtable_get(env, rtbl, x, NULL);
    if (a == mkcl_cat_terminating || a == mkcl_cat_whitespace) {
      mkcl_unread_char(env, x, in);
      break;
    }
    if (a == mkcl_cat_single_escape || a == mkcl_cat_multiple_escape ||
	(x != '0' && x != '1'))
      {
	mkcl_FEreader_error(env, "Character ~:C is not allowed after #*",
		       in, 1, MKCL_CODE_CHAR(x));
      }
    MKCL_TEMP_STACK_PUSH(env, MKCL_MAKE_FIXNUM(x == '1'));
  }
  if (mkcl_Null(d)) {
    dim = dimcount;
  } else {
    dim = mkcl_fixnum_in_range(env, @'make-array',"dimension",d,0,MKCL_ADIMLIM);
    if (dimcount > dim)
      mkcl_FEreader_error(env, "Too many elements in #*....", in, 0);
    if (dim && (dimcount == 0))
      mkcl_FEreader_error(env, "Cannot fill the bit-vector #*.", in, 0);
    else last = MKCL_TEMP_STACK_REF(env,-1);
  }
  x = mkcl_alloc_simple_vector(env, dim, mkcl_aet_bit);
  for (i = 0; i < dim; i++) {
    elt = (i < dimcount) ? env->temp_stack[sp+i] : last; /* FIXME: Possible unchecked overflow of "env->temp_stack" here! JCB */
    if (elt == MKCL_MAKE_FIXNUM(0))
      mkcl_bit_bundle(x->vector.self.bit, i) &= ~(mkcl_bundle_bit_mask(i));
    else
      mkcl_bit_bundle(x->vector.self.bit, i) |= mkcl_bundle_bit_mask(i);
  }
  MKCL_TEMP_STACK_POP_N_UNSAFE(env, dimcount);
  @(return x);
}

static mkcl_object
sharp_colon_reader(MKCL, mkcl_object in, mkcl_object ch, mkcl_object d)
{
  mkcl_object rtbl = mkcl_current_readtable(env);
  enum mkcl_chattrib a;
  bool escape_flag;
  mkcl_character c;
  mkcl_object output, token;

  if (d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, ':', in, d);
  c = mkcl_read_char_noeof(env, in);
  a = mkcl_readtable_get(env, rtbl, c, NULL);
  escape_flag = FALSE;
  token = mk_si_get_buffer_string(env);
  goto L;
  for (;;) {
    mkcl_string_push_extend(env, token, c);
  K:
    c = mkcl_read_char(env, in);
    if (c == EOF)
      goto M;
    a = mkcl_readtable_get(env, rtbl, c, NULL);
  L:
    if (a == mkcl_cat_single_escape) {
      c = mkcl_read_char_noeof(env, in);
      a = mkcl_cat_constituent;
      escape_flag = TRUE;
    } else if (a == mkcl_cat_multiple_escape) {
      escape_flag = TRUE;
      for (;;) {
	c = mkcl_read_char_noeof(env, in);
	a = mkcl_readtable_get(env, rtbl, c, NULL);
	if (a == mkcl_cat_single_escape) {
	  c = mkcl_read_char_noeof(env, in);
	  /* a = mkcl_cat_constituent; */ /* This value is said to be unused. */
	} else if (a == mkcl_cat_multiple_escape)
	  break;
	mkcl_string_push_extend(env, token, c);
      }
      goto K;
    } else if (mkcl_lower_case_p(c))
      c = mkcl_char_upcase(c);
    if (a == mkcl_cat_whitespace || a == mkcl_cat_terminating)
      break;
  }
  mkcl_unread_char(env, c, in);

 M:
  if (read_suppress(env)) {
    output = mk_cl_Cnil;
  } else {
    output = mk_cl_make_symbol(env, token);
  }
  mk_si_put_buffer_string(env, token);
  @(return output);
}

static mkcl_object
sharp_dot_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  if (d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, '.', in, d);
  c = mkcl_read_object_non_recursive(env, in);
  if (c == MKCL_OBJNULL)
    mkcl_FEend_of_file(env, in);
  if (read_suppress(env))
    @(return mk_cl_Cnil);
  if (mkcl_symbol_value(env, @'*read-eval*') == mk_cl_Cnil)
    mkcl_FEreader_error(env, "Cannot evaluate the form #.~A", in, 1, c);
  c = mk_si_eval_in_env(env, 1, c);
  @(return c);
}

static mkcl_object
read_number(MKCL, mkcl_object in, int radix, mkcl_object macro_char)
{
  mkcl_index i;
  mkcl_object x;
  mkcl_object token = read_constituent(env, in);
  if (token == mk_cl_Cnil) {
    x = mk_cl_Cnil;
  } else {
    x = mkcl_parse_number(env, token, 0, TOKEN_STRING_FILLP(token), &i, radix);
    if (x == MKCL_OBJNULL || x == mk_cl_Cnil || i != TOKEN_STRING_FILLP(token)) {
      mkcl_FEreader_error(env, "Cannot parse the #~A readmacro.", in, 1,
		     macro_char);
    }
    if (mk_cl_rationalp(env, x) == mk_cl_Cnil) {
      mkcl_FEreader_error(env, "The float ~S appeared after the #~A readmacro.",
		     in, 2, x, macro_char);
    }
    mk_si_put_buffer_string(env, token);
  }
  return x;
}

static mkcl_object
sharp_B_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  if(d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, 'B', in, d);
  @(return (read_number(env, in, 2, MKCL_CODE_CHAR('B'))));
}

static mkcl_object
sharp_O_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  if(d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, 'O', in, d);
  @(return (read_number(env, in, 8, MKCL_CODE_CHAR('O'))));
}

static mkcl_object
sharp_X_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  if(d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, 'X', in, d);
  @(return (read_number(env, in, 16, MKCL_CODE_CHAR('X'))));
}

static mkcl_object
sharp_R_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  int radix;
  if (read_suppress(env))
    radix = 10;
  else if (MKCL_FIXNUMP(d)) {
    radix = mkcl_fixnum_to_word(d);
    if (radix > 36 || radix < 2)
      mkcl_FEreader_error(env, "~S is an illegal radix.", in, 1, d);
  } else {
    mkcl_FEreader_error(env, "No radix was supplied in the #R readmacro.", in, 0);
  }
  @(return (read_number(env, in, radix, MKCL_CODE_CHAR('R'))));
}

#define sharp_A_reader void_reader
#define sharp_S_reader void_reader

static mkcl_object
sharp_eq_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object pair, value;
  mkcl_object sharp_eq_context = MKCL_SYM_VAL(env, @'si::*sharp-eq-context*');

  if (read_suppress(env)) { @(return); } /* Why is it returning nothing? JCB */
  if (mkcl_Null(d))
    mkcl_FEreader_error(env, "The #= readmacro requires an argument.", in, 0);
  if (mkcl_assql(env, d, sharp_eq_context) != mk_cl_Cnil)
    mkcl_FEreader_error(env, "Duplicate definitions for #~D=.", in, 1, d);
  pair = mkcl_list1(env, d);
  MKCL_SETQ(env, @'si::*sharp-eq-context*', MKCL_CONS(env, pair, sharp_eq_context));
  value = mkcl_read_object(env, in);
  if (value == pair)
    mkcl_FEreader_error(env, "#~D# is defined by itself.", in, 1, d);
  MKCL_RPLACD(pair, value);
  @(return value);
}

static mkcl_object
sharp_sharp_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object pair;

  if (read_suppress(env)) { @(return mk_cl_Cnil); }
  if (mkcl_Null(d))
    mkcl_FEreader_error(env, "The ## readmacro requires an argument.", in, 0);
  pair = mkcl_assq(env, d, MKCL_SYM_VAL(env, @'si::*sharp-eq-context*'));
  if (pair != mk_cl_Cnil)
    @(return pair);
  mkcl_FEreader_error(env, "#~D# is undefined.", in, 1, d);
}

static mkcl_object
do_patch_sharp(MKCL, mkcl_object x)
{
  if (mkcl_Null(x)) return(x);

  switch (mkcl_type_of(x))
    {
    case mkcl_t_cons:
      {
        mkcl_object y = x;
        mkcl_object *place = &x;
        do {
          /* This was the result of a #d# */
          if (MKCL_CAR(y) == MKCL_OBJNULL) {
            *place = MKCL_CDR(y);
            return x;
          } else {
            MKCL_RPLACA(y, do_patch_sharp(env, MKCL_CAR(y)));
          }
          place = &MKCL_CONS_CDR(y);
          y = MKCL_CONS_CDR(y);
        } while (MKCL_CONSP(y));
      }
      break;
    case mkcl_t_vector:
      if (x->vector.elttype == mkcl_aet_object)
        {
          mkcl_index i;
          for (i = 0;  i < x->vector.fillp;  i++)
            x->vector.self.t[i] = do_patch_sharp(env, x->vector.self.t[i]);
        }
      break;
    case mkcl_t_array:
      if (x->vector.elttype == mkcl_aet_object)
        {
          mkcl_index i, j;
          for (i = 0, j = 1;  i < x->array.rank;  i++)
            j *= x->array.dims[i];
          for (i = 0;  i < j;  i++)
            x->array.self.t[i] = do_patch_sharp(env, x->array.self.t[i]);
        }
      break;
    case mkcl_t_complex:
      {
        mkcl_object r = do_patch_sharp(env, x->_complex.real);
        mkcl_object i = do_patch_sharp(env, x->_complex.imag);
        if (r != x->_complex.real || i != x->_complex.imag) {
          mkcl_object c = mkcl_make_complex(env, r, i);
          x->_complex = c->_complex;
        }
      }
      break;
    case mkcl_t_bclosure:
      {
        x->bclosure.lex = do_patch_sharp(env, x->bclosure.lex);
        x = x->bclosure.code = do_patch_sharp(env, x->bclosure.code);
      }
      goto mkcl_t_bytecode_case;
    case mkcl_t_bytecode:
    mkcl_t_bytecode_case:
      {
        mkcl_index i = 0;
        x->bytecode.name = do_patch_sharp(env, x->bytecode.name);
        x->bytecode.definition = do_patch_sharp(env, x->bytecode.definition);
        for (i = 0; i < x->bytecode.data_size; i++) {
          x->bytecode.data[i] = do_patch_sharp(env, x->bytecode.data[i]);
        }
      }
      break;
    default: break;
    }
  return(x);
}

static mkcl_object
patch_sharp(MKCL, mkcl_object x)
{
  mkcl_object sharp_eq_context = MKCL_SYM_VAL(env, @'si::*sharp-eq-context*');
  mkcl_object pairs;

  pairs = sharp_eq_context;
  mkcl_loop_for_in(env, pairs) { 
    mkcl_object pair = MKCL_CONS_CAR(pairs);
    MKCL_RPLACA(pair, MKCL_OBJNULL);
  } mkcl_end_loop_for_in;

  x = do_patch_sharp(env, x);

  pairs = sharp_eq_context;
  mkcl_loop_for_in(env, pairs) {
    mkcl_object pair = MKCL_CONS_CAR(pairs);
    MKCL_RPLACA(pair, mk_cl_Cnil);
  } mkcl_end_loop_for_in;
  return x;
}

#define sharp_plus_reader void_reader
#define sharp_minus_reader void_reader
#define sharp_less_than_reader void_reader
#define sharp_whitespace_reader void_reader
#define sharp_right_parenthesis_reader void_reader

static mkcl_object
sharp_vertical_bar_reader(MKCL, mkcl_object in, mkcl_object ch, mkcl_object d)
{
  int c;
  int level = 0;

  if (d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, '|', in, d);
  for (;;) {
    c = mkcl_read_char_noeof(env, in);
  L:
    if (c == '#') {
      c = mkcl_read_char_noeof(env, in);
      if (c == '|')
	level++;
    } else if (c == '|') {
      c = mkcl_read_char_noeof(env, in);
      if (c == '#') {
	if (level == 0)
	  break;
	else
	  --level;
      } else
	goto L;
    }
  }
  @(return);
  /*  no result  */
}

static mkcl_object
default_dispatch_macro_fun(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_FEreader_error(env, "No dispatch function defined for character ~s.", in, 1, c);
}

/*
	#P" ... " returns the pathname with namestring ... .
*/
static mkcl_object
sharp_P_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  bool suppress = read_suppress(env);
  if (d != mk_cl_Cnil && !suppress)
    extra_argument(env, 'P', in, d);
  d = mkcl_read_object(env, in);
  if (suppress) {
    d = mk_cl_Cnil;
  } else {
    d = mk_cl_parse_namestring(env, 3, d, mk_cl_Cnil, mk_cl_Cnil);
  }
  @(return d);
}

/*
	#$ fixnum returns a random-state with the fixnum
	as its content.
*/
static mkcl_object
sharp_dollar_reader(MKCL, mkcl_object in, mkcl_object c, mkcl_object d)
{
  mkcl_object rs;
  if (d != mk_cl_Cnil && !read_suppress(env))
    extra_argument(env, '$', in, d);
  c = mkcl_read_object(env, in);
  rs = mkcl_alloc_raw_random(env);
  rs->random.value = c;
  @(return rs);
}

/*
	readtable routines
*/

mkcl_object
mkcl_copy_readtable(MKCL, mkcl_object from, mkcl_object to)
{
  mkcl_call_stack_check(env);
  mkcl_assert_type_readtable(env, from);
  if (!mkcl_Null(to)) mkcl_assert_type_readtable(env, to);

  const size_t entry_bytes = sizeof(struct mkcl_readtable_entry);
  const size_t total_bytes = entry_bytes * MKCL_RTABSIZE;
  struct mkcl_readtable_entry * __restrict__ to_rtab
    = (struct mkcl_readtable_entry *) mkcl_alloc_align(env, total_bytes, entry_bytes);
  enum mkcl_readtable_case to_read_case;
  mkcl_object __restrict__ to_hash;
  mkcl_index i;
  volatile bool locked = false;

  MKCL_UNWIND_PROTECT_BEGIN(env) {
    mkcl_interrupt_status old_intr;

    mkcl_get_interrupt_status(env, &old_intr);
    mkcl_disable_interrupts(env);
    READTABLE_LOCK(from); locked = true;
    mkcl_set_interrupt_status(env, &old_intr);

    struct mkcl_readtable_entry * from_rtab = from->readtable.table;
    memcpy(to_rtab, from_rtab, total_bytes);
    for (i = 0;  i < MKCL_RTABSIZE;  i++) {
      mkcl_object d = from_rtab[i].dispatch;
      if (mkcl_type_of(d) == mkcl_t_hashtable) {
	d = mk_si_copy_hash_table(env, d);
      }
      to_rtab[i].dispatch = d;
    }
    to_read_case = from->readtable.read_case;
    if (!mkcl_Null(from->readtable.hash)) {
      to_hash = mk_si_copy_hash_table(env, from->readtable.hash);
    } else {
      to_hash = mk_cl_Cnil;
    }
  } MKCL_UNWIND_PROTECT_EXIT {
    if (locked) READTABLE_UNLOCK(from);
  } MKCL_UNWIND_PROTECT_END;

  if (mkcl_Null(to))
    {
      mkcl_interrupt_status old_intr;
      mkcl_object __restrict__ output = mkcl_alloc_raw_readtable(env);
#if defined(MKCL_WINDOWS)
#if 0
      output->readtable.lock = CreateMutex(NULL, FALSE, mkcl_handle_debug_name(env, "readtable lock"));
      if ( output->readtable.lock == NULL )
	mkcl_FEwin32_error(env, "mkcl_copy_readtable failed to create readtable lock.", 0);
#else
      InitializeCriticalSection(&(output->readtable.lock));
#endif
#else
      const pthread_mutexattr_t * const mutexattr = mkcl_normal_mutexattr;

      if (pthread_mutex_init(&(output->readtable.lock), mutexattr))
	mkcl_C_lose(env, "mkcl_copy_readtable failed on pthread_mutex_init.");
#endif
      mk_si_set_finalizer(env, output, mk_cl_Ct); /* The mutex needs to be deallocated at some point. */

      mkcl_get_interrupt_status(env, &old_intr);
      mkcl_disable_interrupts(env);
      READTABLE_LOCK(output);
      output->readtable.table = to_rtab;
      output->readtable.read_case = to_read_case;
      output->readtable.hash = to_hash;
      READTABLE_UNLOCK(output);
      mkcl_set_interrupt_status(env, &old_intr);

      return output;
    }
  else
    {
      mkcl_interrupt_status old_intr;
      
      mkcl_get_interrupt_status(env, &old_intr);
      mkcl_disable_interrupts(env);
      READTABLE_LOCK(to);
      to->readtable.read_case = to_read_case;
      to->readtable.table = to_rtab;
      to->readtable.hash = to_hash;
      READTABLE_UNLOCK(to);
      mkcl_set_interrupt_status(env, &old_intr);
      
      return to;
    }
}

mkcl_object
mkcl_current_readtable(MKCL)
{
  mkcl_object r;

  /* INV: *readtable* always has a value */
  r = MKCL_SYM_VAL(env, @'*readtable*');
  if (mkcl_type_of(r) != mkcl_t_readtable) {
    MKCL_SETQ(env, @'*readtable*',
	      mkcl_copy_readtable(env, mkcl_core.standard_readtable, mk_cl_Cnil));
    mkcl_FEerror(env, "The value of *READTABLE*, ~S, was not a readtable.", 1, r);
  }
  return r;
}

int
mkcl_current_read_base(MKCL)
{
  mkcl_object x;

  /* INV: *READ-BASE* always has a value */
  x = MKCL_SYM_VAL(env, @'*read_base*');
  if (MKCL_FIXNUMP(x)) {
    mkcl_word b = mkcl_fixnum_to_word(x);
    if (b >= 2 && b <= 36)
      return b;
  }
  MKCL_SETQ(env, @'*read_base*', MKCL_MAKE_FIXNUM(10));
  mkcl_FEerror(env, "The value of *READ-BASE*, ~S, was illegal.", 1, x);
}

char
mkcl_current_read_default_float_format(MKCL)
{
  mkcl_object x;

  /* INV: *READ-DEFAULT-FLOAT-FORMAT* is always bound to something */
  x = MKCL_SYM_VAL(env, @'*read-default-float-format*');
  if (x == @'single-float' || x == @'short-float')
    return 'F';
  if (x == @'double-float')
    return 'D';
  if (x == @'long-float') {
#ifdef MKCL_LONG_FLOAT
    return 'L';
#else
    return 'D';
#endif
  }
  MKCL_SETQ(env, @'*read-default-float-format*', @'single-float');
  mkcl_FEerror(env, "The value of *READ-DEFAULT-FLOAT-FORMAT*, ~S, was illegal.", 1, x);
}

static mkcl_object
stream_or_default_input(MKCL, mkcl_object stream)
{
  if (mkcl_Null(stream))
    return MKCL_SYM_VAL(env, @'*standard-input*');
  if (stream == mk_cl_Ct)
    return MKCL_SYM_VAL(env, @'*terminal-io*');
  return stream;
}

@(defun read (&optional (strm mk_cl_Cnil) (eof_errorp mk_cl_Ct) eof_value recursivep)
  mkcl_object x;
@
  strm = stream_or_default_input(env, strm);
  if (mkcl_Null(recursivep)) {
    x = mkcl_read_object_non_recursive(env, strm);
  } else {
    x = mkcl_read_object(env, strm);
  }
  if (x == MKCL_OBJNULL) {
    if (mkcl_Null(eof_errorp))
      @(return eof_value);
    mkcl_FEend_of_file(env, strm);
  }
  /* Skip whitespace characters, but stop at beginning of new line or token */
  if (mkcl_Null(recursivep)) {
    mkcl_object rtbl = mkcl_current_readtable(env);
    mkcl_character c = mkcl_read_char(env, strm);
    if (c != EOF && (mkcl_readtable_get(env, rtbl, c, NULL) != mkcl_cat_whitespace)) {
      mkcl_unread_char(env, c, strm);
    }
  }
  @(return x);
@)

@(defun read_preserving_whitespace
	(&optional (strm mk_cl_Cnil)
		   (eof_errorp mk_cl_Ct)
		   eof_value
		   recursivep)
  mkcl_object x;
@
  strm = stream_or_default_input(env, strm);
  if (mkcl_Null(recursivep)) {
    x = mkcl_read_object_non_recursive(env, strm);
  } else {
    x = mkcl_read_object(env, strm);
  }
  if (x == MKCL_OBJNULL) {
    if (mkcl_Null(eof_errorp))
      @(return eof_value)
	mkcl_FEend_of_file(env, strm);
  }
  @(return x);
@)

static mkcl_object
do_read_delimited_list(MKCL, int d, mkcl_object in, bool proper_list)
{
  int after_dot = 0;
  bool suppress = read_suppress(env);
  mkcl_object x, y = mk_cl_Cnil;
  mkcl_object *p = &y;
  do {
    x = mkcl_read_object_with_delimiter(env, in, d, 0, mkcl_cat_constituent);
    if (x == MKCL_OBJNULL) {
      /* End of the list. */
      if (after_dot == 1) {
	/* Something like (1 . ) */
	mkcl_FEreader_error(env, "Object missing after a list dot", in, 0);
      }
      return y;
    } else if (x == @'si::.') {
      if (proper_list) {
	mkcl_FEreader_error(env, "A dotted list was found where a proper list was expected.", in, 0);
      }
      if (p == &y) {
	/* Something like (. 2) */
	mkcl_FEreader_error(env, "A dot appeared after a left parenthesis.", in, 0);
      }
      if (after_dot) {
	/* Something like (1 . . 2) */
	mkcl_FEreader_error(env, "Two dots appeared consecutively.", in, 0);
      }
      after_dot = 1;
    } else if (after_dot) {
      if (after_dot++ > 1) {
	/* Something like (1 . 2 3) */
	mkcl_FEreader_error(env, "Too many objects after a list dot", in, 0);
      }
      *p = x;
    } else if (!suppress) {
      *p = mkcl_list1(env, x);
      p = &MKCL_CONS_CDR(*p);
    }
  } while (1);
}

@(defun read_delimited_list (d &optional (strm mk_cl_Cnil) recursivep)
  mkcl_object l;
  int delimiter;
@
  delimiter = mkcl_char_code(env, d);
  strm = stream_or_default_input(env, strm);
  if (!mkcl_Null(recursivep)) {
    l = do_read_delimited_list(env, delimiter, strm, 1);
  } else {
    mkcl_bds_bind(env, @'si::*sharp-eq-context*', mk_cl_Cnil);
    mkcl_bds_bind(env, @'si::*backq-level*', MKCL_MAKE_FIXNUM(0));
    l = do_read_delimited_list(env, delimiter, strm, 1);
    if (!mkcl_Null(MKCL_SYM_VAL(env, @'si::*sharp-eq-context*')))
      l = patch_sharp(env, l);
    mkcl_bds_unwind_n(env, 2);
  }
  @(return l);
@)

@(defun read_line (&optional (strm mk_cl_Cnil) (eof_errorp mk_cl_Ct) eof_value recursivep)
	mkcl_character c;
	mkcl_object token, value0, value1;
@
  strm = stream_or_default_input(env, strm);
  if (mkcl_type_of(strm) != mkcl_t_stream) {
    token = mkcl_funcall1(env, @+'gray::stream-read-line', strm);
    if (!mkcl_Null(MKCL_VALUES(1))) {
      c = EOF;
      goto EOFCHK;
    }
    return token;
  }
  token = mk_si_get_buffer_string(env);
  do {
    c = mkcl_read_char(env, strm);
    if (c == EOF || c == '\n')
      break;
    mkcl_string_push_extend(env, token, c);
  } while(1);
 EOFCHK:
  if (c == EOF && TOKEN_STRING_FILLP(token) == 0) {
    if (!mkcl_Null(eof_errorp))
      mkcl_FEend_of_file(env, strm);
    value0 = eof_value;
    value1 = mk_cl_Ct;
  } else {
#ifdef MKCL_NEWLINE_IS_CRLF	/* From \r\n, ignore \r */
    if (TOKEN_STRING_FILLP(token) > 0 &&
	TOKEN_STRING_CHAR_CMP(token,TOKEN_STRING_FILLP(token)-1,'\r'))
      TOKEN_STRING_FILLP(token)--;
#endif
#ifdef MKCL_NEWLINE_IS_LFCR	/* From \n\r, ignore \r */
    mkcl_read_char(strm);
#endif
    value0 = mk_cl_copy_seq(env, token);
    value1 = (c == EOF? mk_cl_Ct : mk_cl_Cnil);
  }
  mk_si_put_buffer_string(env, token);
  @(return value0 value1);
@)

@(defun read-char (&optional (strm mk_cl_Cnil) (eof_errorp mk_cl_Ct) eof_value recursivep)
	mkcl_character c;
	mkcl_object output;
@
  strm = stream_or_default_input(env, strm);
  c = mkcl_read_char(env, strm);
  if (c != EOF)
    output = MKCL_CODE_CHAR(c);
  else if (mkcl_Null(eof_errorp))
    output = eof_value;
  else
    mkcl_FEend_of_file(env, strm);
  @(return output);
@)

@(defun unread_char (c &optional (strm mk_cl_Cnil))
@
  /* INV: unread_char() checks the type `c' */
  strm = stream_or_default_input(env, strm);
  mkcl_unread_char(env, mkcl_char_code(env, c), strm);
  @(return mk_cl_Cnil);
@)

@(defun peek-char (&optional peek_type (strm mk_cl_Cnil) (eof_errorp mk_cl_Ct) eof_value recursivep)
  mkcl_character c;
  mkcl_object rtbl = mkcl_current_readtable(env);
@
  strm = stream_or_default_input(env, strm);
  c = mkcl_peek_char(env, strm);
  if (c != EOF && !mkcl_Null(peek_type)) {
    if (peek_type == mk_cl_Ct) {
      do {
	/* If the character is not a whitespace, output */
	if (mkcl_readtable_get(env, rtbl, c, NULL) != mkcl_cat_whitespace)
	  break;
	/* Otherwise, read the whitespace and peek the
	 * next character */
	mkcl_read_char(env, strm);
	c = mkcl_peek_char(env, strm);
      } while (c != EOF);
    } else {
      do {
	/* If the character belongs to the given class,
	 * we're done. */
	if (mkcl_char_eq(env, MKCL_CODE_CHAR(c), peek_type))
	  break;
	/* Otherwise, consume the character and
	 * peek the next one. */
	mkcl_read_char(env, strm);
	c = mkcl_peek_char(env, strm);
      } while (c != EOF);
    }
  }
  if (c != EOF) {
    eof_value = MKCL_CODE_CHAR(c);
  } else if (!mkcl_Null(eof_errorp)) {
    mkcl_FEend_of_file(env, strm);
  }
  @(return eof_value);
@)

@(defun listen (&optional (strm mk_cl_Cnil))
@
  strm = stream_or_default_input(env, strm);
  @(return ((mkcl_listen_stream(env, strm) == MKCL_LISTEN_AVAILABLE) ? mk_cl_Ct : mk_cl_Cnil));
@)

@(defun read_char_no_hang (&optional (strm mk_cl_Cnil) (eof_errorp mk_cl_Ct) eof_value recursivep)
  int f;
@
  strm = stream_or_default_input(env, strm);
  if (mkcl_type_of(strm) != mkcl_t_stream) {
    mkcl_object output = mkcl_funcall1(env, @+'gray::stream-read-char-no-hang', strm);
    if (output == @':eof')
      goto END_OF_FILE;
    @(return output);
  }
  f = mkcl_listen_stream(env, strm);
  if (f == MKCL_LISTEN_AVAILABLE) {
    mkcl_character c = mkcl_read_char(env, strm);
    if (c != EOF) {
      @(return MKCL_CODE_CHAR(c));
    }
  } else if (f == MKCL_LISTEN_NO_CHAR) {
    @(return @'nil');
  }
  /* We reach here if there was an EOF */
 END_OF_FILE:
  if (mkcl_Null(eof_errorp))
    { @(return eof_value); }
  else
    mkcl_FEend_of_file(env, strm);
@)

@(defun clear_input (&optional (strm mk_cl_Cnil))
@
  strm = stream_or_default_input(env, strm);
  mkcl_clear_input(env, strm);
  @(return mk_cl_Cnil);
@)

@(defun parse_integer (strng
		       &key (start MKCL_MAKE_FIXNUM(0))
			    end
			    (radix MKCL_MAKE_FIXNUM(10))
			    junk_allowed
		       &aux x)
  mkcl_index s, e, ep;
  mkcl_object rtbl = mkcl_current_readtable(env);
@ 
{
  strng = mkcl_check_type_string(env, @'parse-integer', strng);
  mkcl_get_string_start_end(env, strng, start, end, &s, &e);
  if (!MKCL_FIXNUMP(radix) ||
      mkcl_fixnum_to_word(radix) < 2 || mkcl_fixnum_to_word(radix) > 36)
    mkcl_FEerror(env, "~S is an illegal radix.", 1, radix);
  while (s < e && mkcl_readtable_get(env, rtbl, mkcl_char(env, strng, s), NULL) == mkcl_cat_whitespace) s++;
  if (s >= e) {
    if (junk_allowed != mk_cl_Cnil)
      { @(return mk_cl_Cnil MKCL_MAKE_FIXNUM(s)); }
    else
      goto CANNOT_PARSE;
  }
  x = mkcl_parse_integer(env, strng, s, e, &ep, mkcl_fixnum_to_word(radix));
  if (x == MKCL_OBJNULL) {
    if (junk_allowed != mk_cl_Cnil) {
      @(return mk_cl_Cnil MKCL_MAKE_FIXNUM(ep));
    } else {
      goto CANNOT_PARSE;
    }
  }
  if (junk_allowed != mk_cl_Cnil) {
    @(return x MKCL_MAKE_FIXNUM(ep));
  }
  for (s = ep; s < e; s++)
    {
      if (mkcl_readtable_get(env, rtbl, mkcl_char(env, strng, s), NULL) != mkcl_cat_whitespace)
	{
	CANNOT_PARSE:		
	  mkcl_FEparse_error(env, "Cannot parse an integer in the string ~S.",
			     mk_cl_Cnil, 1, strng);
	}
    }
  @(return x MKCL_MAKE_FIXNUM(e));
 }
@)

@(defun read_byte (binary_input_stream &optional (eof_errorp mk_cl_Ct) eof_value)
	mkcl_object c;
@
  c = mkcl_read_byte(env, binary_input_stream);
  if (c == mk_cl_Cnil) {
    if (mkcl_Null(eof_errorp))
      { @(return eof_value); }
    else
      mkcl_FEend_of_file(env, binary_input_stream);
  }
  @(return c);
@)

@(defun read_sequence (sequence stream &key (start MKCL_MAKE_FIXNUM(0)) end)
@
  if (mkcl_type_of(stream) != mkcl_t_stream)
    return mkcl_funcall4(env, @+'gray::stream-read-sequence', stream, sequence, start, end);
  else
    return mk_si_do_read_sequence(env, sequence, stream, start, end);
@)


@(defun copy_readtable (&o (from mkcl_current_readtable(env)) to)
@
  if (mkcl_Null(from)) {
    to = mkcl_copy_readtable(env, mkcl_core.standard_readtable, to);
  } else {
    to = mkcl_copy_readtable(env, from, to);
  }
  @(return to);
@)

mkcl_object
mk_cl_readtable_case(MKCL, mkcl_object r)
{
  mkcl_call_stack_check(env);
  mkcl_assert_type_readtable(env, r);
  switch (r->readtable.read_case) {
  case mkcl_case_upcase: r = @':upcase'; break;
  case mkcl_case_downcase: r = @':downcase'; break;
  case mkcl_case_invert: r = @':invert'; break;
  case mkcl_case_preserve: r = @':preserve';
  }
  @(return r);
}

mkcl_object
mk_si_readtable_case_set(MKCL, mkcl_object r, mkcl_object mode)
{
  mkcl_call_stack_check(env);
  mkcl_assert_type_readtable(env, r);
  if (mode == @':upcase') {
    r->readtable.read_case = mkcl_case_upcase;
  } else if (mode == @':downcase') {
    r->readtable.read_case = mkcl_case_downcase;
  } else if (mode == @':preserve') {
    r->readtable.read_case = mkcl_case_preserve;
  } else if (mode == @':invert') {
    r->readtable.read_case = mkcl_case_invert;
  } else {
    mkcl_FEwrong_type_argument(env,
			  mk_cl_list(env, 5,
				  @'member', @':upcase',
				  @':downcase', @':preserve',
				  @':invert'),
			  mode);
  }
  @(return mode);
}

mkcl_object
mk_cl_readtablep(MKCL, mkcl_object readtable)
{
  mkcl_call_stack_check(env);
  @(return ((mkcl_type_of(readtable) == mkcl_t_readtable) ? mk_cl_Ct : mk_cl_Cnil));
}

enum mkcl_chattrib 
mkcl_readtable_get(MKCL, mkcl_object readtable, mkcl_character c, mkcl_object *macro_or_table)
{
  mkcl_object m;
  enum mkcl_chattrib cat;
  if (c >= MKCL_RTABSIZE) {
    mkcl_object hash = readtable->readtable.hash;
    cat = mkcl_cat_constituent;
    m = mk_cl_Cnil;
    if (!mkcl_Null(hash)) {
      mkcl_object pair = mkcl_gethash_safe(env, MKCL_CODE_CHAR(c), hash, mk_cl_Cnil);
      if (!mkcl_Null(pair)) {
	cat = mkcl_fixnum_to_word(MKCL_CONS_CAR(pair));
	m = MKCL_CONS_CDR(pair);
      }
    }
  } else {
    m = readtable->readtable.table[c].dispatch;
    cat = readtable->readtable.table[c].syntax_type;
  }
  if (macro_or_table) *macro_or_table = m;
  return cat;
}

void
mkcl_readtable_set(MKCL, mkcl_object readtable, mkcl_character c, enum mkcl_chattrib cat, mkcl_object macro_or_table)
{
  volatile bool locked = false;

  MKCL_UNWIND_PROTECT_BEGIN(env) {
    mkcl_interrupt_status old_intr;

    mkcl_get_interrupt_status(env, &old_intr);
    mkcl_disable_interrupts(env);
    READTABLE_LOCK(readtable); locked = true;
    mkcl_set_interrupt_status(env, &old_intr);

    if (c >= MKCL_RTABSIZE) {
      mkcl_object hash = readtable->readtable.hash;
      if (mkcl_Null(hash)) {
	hash = mk_cl__make_hash_table(env, @'eql', MKCL_MAKE_FIXNUM(128),
				      mkcl_make_singlefloat(env, 1.5f),
				      mkcl_make_singlefloat(env, 0.5f));
	readtable->readtable.hash = hash;
      }
      mkcl_sethash(env, MKCL_CODE_CHAR(c), hash,
		   MKCL_CONS(env, MKCL_MAKE_FIXNUM(cat), macro_or_table));
    } else {
      readtable->readtable.table[c].dispatch = macro_or_table;
      readtable->readtable.table[c].syntax_type = cat;
    }
  } MKCL_UNWIND_PROTECT_EXIT {
    if (locked) READTABLE_UNLOCK(readtable);
  } MKCL_UNWIND_PROTECT_END;
}

bool
mkcl_invalid_constituent_character_p(mkcl_character c)
{
  /* This shoots larger than required by CLHS 2.1.4.2 but at least is in the spirit of it. JCB */
  /* BTW, this hardcodes the ASCII/Unicode encoding. */
  return (c <= 32) || (c == 127);
}

@(defun set_syntax_from_char (tochr fromchr
			      &o (tordtbl mkcl_current_readtable(env))
				 fromrdtbl)
	enum mkcl_chattrib cat;
	mkcl_object dispatch;
	mkcl_word fc, tc;
@
  volatile bool locked = false;

  if (mkcl_Null(fromrdtbl))
    fromrdtbl = mkcl_core.standard_readtable;
  mkcl_assert_type_readtable(env, fromrdtbl);
  mkcl_assert_type_readtable(env, tordtbl);
  fc = mkcl_char_code(env, fromchr);
  tc = mkcl_char_code(env, tochr);

  MKCL_UNWIND_PROTECT_BEGIN(env) {
    mkcl_interrupt_status old_intr;

    mkcl_get_interrupt_status(env, &old_intr);
    mkcl_disable_interrupts(env);
    READTABLE_LOCK(fromrdtbl); locked = true;
    mkcl_set_interrupt_status(env, &old_intr);

    cat = mkcl_readtable_get(env, fromrdtbl, fc, &dispatch);
    if (mkcl_type_of(dispatch) == mkcl_t_hashtable) {
      dispatch = mk_si_copy_hash_table(env, dispatch);
    }
  } MKCL_UNWIND_PROTECT_EXIT {
    if (locked) READTABLE_UNLOCK(fromrdtbl);
  } MKCL_UNWIND_PROTECT_END;
  mkcl_readtable_set(env, tordtbl, tc, cat, dispatch);
  @(return mk_cl_Ct);
@)

@(defun set_macro_character (c function &optional non_terminating_p
			     (readtable mkcl_current_readtable(env)))
@
  mkcl_readtable_set(env, readtable, mkcl_char_code(env, c),
		     mkcl_Null(non_terminating_p)
		     ? mkcl_cat_terminating
		     : mkcl_cat_non_terminating,
		     function);
  @(return mk_cl_Ct);
@)

@(defun get_macro_character (c &optional readtable)
  enum mkcl_chattrib cat;
  mkcl_object dispatch;
@
  if (mkcl_Null(readtable))
    readtable = mkcl_core.standard_readtable;
  cat = mkcl_readtable_get(env, readtable, mkcl_char_code(env, c), &dispatch);
  if (mkcl_type_of(dispatch) == mkcl_t_hashtable)
    dispatch = mkcl_core.dispatch_reader;
  @(return dispatch ((cat == mkcl_cat_non_terminating) ? mk_cl_Ct : mk_cl_Cnil));
@)

@(defun make_dispatch_macro_character (chr
	&optional non_terminating_p (readtable mkcl_current_readtable(env)))
	enum mkcl_chattrib cat;
	mkcl_object table;
	int c;
@
  mkcl_assert_type_readtable(env, readtable);
  c = mkcl_char_code(env, chr);
  cat = mkcl_Null(non_terminating_p)? mkcl_cat_terminating : mkcl_cat_non_terminating;
  table = mk_cl__make_hash_table(env, @'eql', MKCL_MAKE_FIXNUM(128),
				 mkcl_make_singlefloat(env, 1.5f),
				 mkcl_make_singlefloat(env, 0.5f));
  mkcl_readtable_set(env, readtable, c, cat, table);
  @(return mk_cl_Ct);
@)

@(defun set_dispatch_macro_character (dspchr subchr fnc
				      &optional (readtable mkcl_current_readtable(env)))
  mkcl_object table;
  mkcl_word subcode;
@
  volatile bool locked = false;

  mkcl_assert_type_readtable(env, readtable);
  mkcl_readtable_get(env, readtable, mkcl_char_code(env, dspchr), &table);
  if (mkcl_type_of(table) != mkcl_t_hashtable) {
    mkcl_FEerror(env, "~S is not a dispatch character.", 1, dspchr);
  }

  MKCL_UNWIND_PROTECT_BEGIN(env) {
    mkcl_interrupt_status old_intr;

    mkcl_get_interrupt_status(env, &old_intr);
    mkcl_disable_interrupts(env);
    READTABLE_LOCK(readtable); locked = true;
    mkcl_set_interrupt_status(env, &old_intr);

    subcode = mkcl_char_code(env, subchr);
    if (mkcl_Null(fnc)) {
      mkcl_remhash(env, MKCL_CODE_CHAR(subcode), table);
    } else {
      mkcl_sethash(env, MKCL_CODE_CHAR(subcode), table, fnc);
    }
    if (mkcl_lower_case_p(subcode)) {
      subcode = mkcl_char_upcase(subcode);
    } else if (mkcl_upper_case_p(subcode)) {
      subcode = mkcl_char_downcase(subcode);
    }
    if (mkcl_Null(fnc)) {
      mkcl_remhash(env, MKCL_CODE_CHAR(subcode), table);
    } else {
      mkcl_sethash(env, MKCL_CODE_CHAR(subcode), table, fnc);
    }
  } MKCL_UNWIND_PROTECT_EXIT {
    if (locked) READTABLE_UNLOCK(readtable);
  } MKCL_UNWIND_PROTECT_END;
  @(return mk_cl_Ct);
@)

@(defun get_dispatch_macro_character (dspchr subchr
				      &optional (readtable mkcl_current_readtable(env)))
  mkcl_object table;
  mkcl_word c;
@
  if (mkcl_Null(readtable)) {
    readtable = mkcl_core.standard_readtable;
  }
  mkcl_assert_type_readtable(env, readtable);
  c = mkcl_char_code(env, dspchr);
  mkcl_readtable_get(env, readtable, c, &table);
  if (mkcl_type_of(table) != mkcl_t_hashtable) {
    mkcl_FEerror(env, "~S is not a dispatch character.", 1, dspchr);
  }
  c = mkcl_char_code(env, subchr);
  
  /* Since macro characters may take a number as argument, it is
     not allowed to turn digits into dispatch macro characters */
  if (mkcl_digitp(c, 10) >= 0)
    { @(return mk_cl_Cnil); }
  @(return mkcl_gethash_safe(env, subchr, table, mk_cl_Cnil));
@)

mkcl_object
mkcl_fast_read_from_cstring(MKCL, char *s)
{
  return mk_si_fast_read_from_base_string(env, mkcl_make_simple_base_string(env, s));
}

mkcl_object
mk_si_fast_read_from_base_string(MKCL, mkcl_object x)
{
  mkcl_object in;

  mkcl_call_stack_check(env);
  /* FIXME! Restricted to base string */
  x = mkcl_check_cl_type(env, @'si::fast-read-from-base-string', x, mkcl_t_base_string);
  in = mkcl_make_string_input_stream(env, x, 0, TOKEN_STRING_FILLP(x), @':utf-8');
  x = mkcl_read_object(env, in);
  if (x == MKCL_OBJNULL)
    mkcl_FEend_of_file(env, in);
  @(return x);
}

mkcl_object
mk_si_standard_readtable(MKCL)
{
  @(return mkcl_core.standard_readtable)
}

static void
extra_argument(MKCL, int c, mkcl_object stream, mkcl_object d)
{
  mkcl_FEreader_error(env, "~S is an extra argument for the #~C readmacro.",
		      stream, 2, d, MKCL_CODE_CHAR(c));
}


#define	make_cf2(e,f)	mkcl_make_cfun(e, (f), mk_cl_Cnil, NULL, 2, NULL)
#define	make_cf3(e,f)	mkcl_make_cfun(e, (f), mk_cl_Cnil, NULL, 3, NULL)

void
mkcl_init_read(MKCL)
{
  mkcl_object __restrict__ r;

#if 0
  mkcl_core.standard_readtable = r = mkcl_alloc_raw_readtable(env);
  mkcl_core.standard_readtable->readtable.read_case = mkcl_case_upcase;
#else
  r = mkcl_alloc_raw_readtable(env);
  r->readtable.read_case = mkcl_case_upcase;
#endif

#if defined(MKCL_WINDOWS)
#if 0
  r->readtable.lock = CreateMutex(NULL, FALSE, mkcl_handle_debug_name(env, "standard readtable lock"));
  if ( r->readtable.lock == NULL )
    mkcl_FEwin32_error(env, "mkcl_init_read failed to create readtable lock.", 0);
#else
  InitializeCriticalSection(&(r->readtable.lock));
#endif
#else
  {
    const pthread_mutexattr_t * const mutexattr = mkcl_normal_mutexattr;

    if (pthread_mutex_init(&(r->readtable.lock), mutexattr))
      mkcl_lose(env, "mkcl_init_read failed on pthread_mutex_init.");
  }
#endif

  /* Someone really paranoid would lock the readtable during its initialization... */
  /* Coverity motivated us to be so. */

  {
    struct mkcl_readtable_entry * rtab
      = (struct mkcl_readtable_entry *) mkcl_alloc(env, MKCL_RTABSIZE * sizeof(struct mkcl_readtable_entry));
    int i;

    for (i = 0;  i < MKCL_RTABSIZE;  i++)
      {
        rtab[i].syntax_type = mkcl_cat_constituent;
        rtab[i].dispatch = mk_cl_Cnil;
      }
    {
      mkcl_interrupt_status old_intr;
      bool locked = false;

      mkcl_get_interrupt_status(env, &old_intr);
      mkcl_disable_interrupts(env);
      READTABLE_LOCK(r); locked = true;
      r->readtable.table = rtab;
      r->readtable.hash = mk_cl_Cnil;
      if (locked) READTABLE_UNLOCK(r);
      mkcl_set_interrupt_status(env, &old_intr);
    }
  }

  mkcl_core.dispatch_reader = make_cf2(env, dispatch_reader_fun);

  mkcl_readtable_set(env, r, '\t', mkcl_cat_whitespace, mk_cl_Cnil);
  mkcl_readtable_set(env, r, '\n', mkcl_cat_whitespace, mk_cl_Cnil);
  mkcl_readtable_set(env, r, '\f', mkcl_cat_whitespace, mk_cl_Cnil);
  mkcl_readtable_set(env, r, '\r', mkcl_cat_whitespace, mk_cl_Cnil);
  mkcl_readtable_set(env, r, ' ', mkcl_cat_whitespace, mk_cl_Cnil);

  mkcl_readtable_set(env, r, '"', mkcl_cat_terminating, make_cf2(env, double_quote_reader));

  mkcl_readtable_set(env, r, '\'', mkcl_cat_terminating, make_cf2(env, single_quote_reader));
  mkcl_readtable_set(env, r, '(', mkcl_cat_terminating, make_cf2(env, left_parenthesis_reader));
  mkcl_readtable_set(env, r, ')', mkcl_cat_terminating, make_cf2(env, right_parenthesis_reader));
  mkcl_readtable_set(env, r, ',', mkcl_cat_terminating, make_cf2(env, comma_reader));
  mkcl_readtable_set(env, r, ';', mkcl_cat_terminating, make_cf2(env, semicolon_reader));
  mkcl_readtable_set(env, r, '\\', mkcl_cat_single_escape, mk_cl_Cnil);
  mkcl_readtable_set(env, r, '`', mkcl_cat_terminating, make_cf2(env, backquote_reader));
  mkcl_readtable_set(env, r, '|', mkcl_cat_multiple_escape, mk_cl_Cnil);

  mkcl_core.default_dispatch_macro = make_cf3(env, default_dispatch_macro_fun);

  mk_cl_make_dispatch_macro_character(env, 3, MKCL_CODE_CHAR('#'), mk_cl_Ct /* non terminating */, r);

  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('C'), make_cf3(env, sharp_C_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('\\'), make_cf3(env, sharp_backslash_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('\''), make_cf3(env, sharp_single_quote_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('('), make_cf3(env, sharp_left_parenthesis_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('*'), make_cf3(env, sharp_asterisk_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR(':'), make_cf3(env, sharp_colon_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('.'), make_cf3(env, sharp_dot_reader), r);
  /*  Used for fasload only. */
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('B'), make_cf3(env, sharp_B_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('O'), make_cf3(env, sharp_O_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('X'), make_cf3(env, sharp_X_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('R'), make_cf3(env, sharp_R_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('A'), @'si::sharp-a-reader', r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('S'), @'si::sharp-s-reader', r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('P'), make_cf3(env, sharp_P_reader), r);

  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('='), make_cf3(env, sharp_eq_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('#'), make_cf3(env, sharp_sharp_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('+'), make_cf3(env, sharp_plus_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('-'), make_cf3(env, sharp_minus_reader), r);
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('|'), make_cf3(env, sharp_vertical_bar_reader), r);
  /*  This is specific to this implementation  */
  mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('$'), make_cf3(env, sharp_dollar_reader), r);

  mkcl_init_backq(env);

  {
    mkcl_object r2 = mkcl_copy_readtable(env, r, mk_cl_Cnil);
    MKCL_SET(@'*readtable*', r2);
    mk_cl_set_dispatch_macro_character(env, 4, MKCL_CODE_CHAR('#'), MKCL_CODE_CHAR('!'), mk_cl_Cnil, r2);
  }
  MKCL_SET(@'*read-default-float-format*', @'single-float');
  mkcl_core.standard_readtable = r;
}

/*
 *----------------------------------------------------------------------
 *
 * mkcl_read_VV --
 *     reads the data vector from stream into vector VV
 *
 * Results:
 *	a CodeBlock object.
 *
 *----------------------------------------------------------------------
 */
mkcl_object
mkcl_read_VV(MKCL,
	     mkcl_object block,
	     void (*entry_point)(MKCL, mkcl_object, mkcl_object),
	     mkcl_object filename)
{
  volatile mkcl_object x;
  mkcl_object old_ptbc = mk_si_packages_in_waiting(env);
  mkcl_index i, len, perm_len, temp_len;
  mkcl_object in;
  mkcl_object *VV, *VVtemp = 0;

#if 0
  {
    volatile bool locked = false;
    MKCL_UNWIND_PROTECT_BEGIN(env) {
      MKCL_LIBC_NO_INTR(env, (MKCL_PACKAGE_LIST_LOCK(), locked = true));
      if ( mkcl_core.packages_to_be_created == MKCL_OBJNULL )
        old_ptbc = mk_cl_Cnil;
      else
        old_ptbc = mk_cl_copy_alist(env, mkcl_core.packages_to_be_created);
    } MKCL_UNWIND_PROTECT_EXIT {
      if (locked) MKCL_PACKAGE_LIST_UNLOCK();
    } MKCL_UNWIND_PROTECT_END;
  }
#endif
  
  if (mkcl_Null(block)) {
    block = mkcl_alloc_raw_codeblock(env);
    block->cblock.self_destruct = FALSE;
    block->cblock.locked = 0;
    block->cblock.handle = NULL;
    block->cblock.data = NULL;
    block->cblock.data_size = 0;
    block->cblock.temp_data = NULL;
    block->cblock.temp_data_size = 0;
    block->cblock.data_text = NULL;
    block->cblock.data_text_size = 0;
    block->cblock.next = mk_cl_Cnil;
    block->cblock.name = mk_cl_Cnil;
    block->cblock.links = mk_cl_Cnil;
    block->cblock.cfuns_size = 0;
    block->cblock.cfuns = NULL;
    block->cblock.source = mk_cl_Cnil;
    block->cblock.fun_ref_syms = NULL;
    block->cblock.fun_refs = NULL;
    block->cblock.cfun_objs = NULL;
    mk_si_set_finalizer(env, block, mk_cl_Ct);
  }
  block->cblock.entry = entry_point;

  in = MKCL_OBJNULL;
  MKCL_UNWIND_PROTECT_BEGIN(env) {
    mkcl_bds_bind(env, @'si::*cblock*', block);

    /* Communicate the library which Cblock we are using, and get
     * back the amount of data to be processed.
     */
    env->function = mk_cl_Cnil;
    (*entry_point)(env, block, filename);
    perm_len = block->cblock.data_size;
    temp_len = block->cblock.temp_data_size;
    len = perm_len + temp_len;
    VV = block->cblock.data 
      = perm_len ? (mkcl_object *)mkcl_alloc(env, perm_len * sizeof(mkcl_object)) : NULL;

    if (perm_len) memset(VV, 0, perm_len * sizeof(*VV));

    if ((len == 0) || (block->cblock.data_text == 0)) goto NO_DATA_LABEL;

    VVtemp = block->cblock.temp_data 
      = temp_len ? (mkcl_object *)mkcl_alloc(env, temp_len * sizeof(mkcl_object)) : NULL;
    if (temp_len)
      memset(VVtemp, 0, temp_len * sizeof(*VVtemp));

    /* Read all data for the library */
    in=mkcl_make_string_input_stream(env,
				     mkcl_make_simple_base_string(env, (char *) block->cblock.data_text),
				     0, block->cblock.data_text_size,
				     @':UTF-8'
				     );
    mkcl_bds_bind(env, @'*read-base*', MKCL_MAKE_FIXNUM(10));
    mkcl_bds_bind(env, @'*read-default-float-format*', @'single-float');
    mkcl_bds_bind(env, @'*read-suppress*', mk_cl_Cnil);
    mkcl_bds_bind(env, @'*readtable*', mkcl_core.standard_readtable);
    mkcl_bds_bind(env, @'*package*', mkcl_core.lisp_package);
    mkcl_bds_bind(env, @'si::*sharp-eq-context*', mk_cl_Cnil);
    mkcl_bds_bind(env, @'si::+reading-fasl-file+', mk_cl_Ct);

    /* This should be :mkcl-compiled */
    x = mkcl_read_object(env, in);
    if ( x != @':MKCL-COMPILED' )
      mk_cl_error(env, 5, @'mkcl::bad-fasl-file', @':pathname', filename, @':reason', @':format');

    /* This should be MKCL version number
       of the MKCL that compiled the file. */
    x = mkcl_read_object(env, in);
    if ( MKCL_VERSION_NUMBER < mkcl_fixnum_to_word(x) )
      mk_cl_error(env, 5, @'mkcl::bad-fasl-file', @':pathname', filename, @':reason', @':version');

    /* This should be MKCL FASL version number at compilation time. */
    x = mkcl_read_object(env, in);
    if ( MKCL_FASL_VERSION != mkcl_fixnum_to_word(x) )
      mk_cl_error(env, 5, @'mkcl::bad-fasl-file', @':pathname', filename, @':reason', @':stale');

    /* CPU identifier */
    x = mkcl_read_object(env, in);

    /* OS family */
    x = mkcl_read_object(env, in);

    /* OS specific version */
    x = mkcl_read_object(env, in);

    for (i = 0 ; i < len; i++) {
      x = mkcl_read_object(env, in);
      if (x == MKCL_OBJNULL) /* end of input? */
	break;
      if (i < perm_len)
	VV[i] = x;
      else
	VVtemp[i-perm_len] = x;
    }
    if (!mkcl_Null(MKCL_SYM_VAL(env, @'si::*sharp-eq-context*'))) {
      while (i--) {
	if (i < perm_len) {
	  VV[i] = patch_sharp(env, VV[i]);
	} else {
	  VVtemp[i-perm_len] = patch_sharp(env, VVtemp[i-perm_len]);
	}
      }
    }
    mkcl_bds_unwind_n(env, 7);

    if (i < len)
      mk_cl_error(env, 5, @'mkcl::bad-fasl-file', @':pathname', filename, @':reason', @':corrupted');

  NO_DATA_LABEL:

    block->cblock.cfun_objs
      = (block->cblock.cfuns_size 
	 ? (mkcl_object *) mkcl_alloc(env, block->cblock.cfuns_size * sizeof(mkcl_object))
	 : NULL);
    for (i = 0; i < block->cblock.cfuns_size; i++) {
      block->cblock.cfun_objs[i] = mk_cl_Cnil;
    }
    for (i = 0; i < block->cblock.cfuns_size; i++) {
      const struct mkcl_cfun *prototype = block->cblock.cfuns+i;

      if (!mkcl_Null(prototype->name))
	{
	  mkcl_index location = mkcl_fixnum_to_word(prototype->name);
	  mkcl_index fname_location = mkcl_fixnum_to_word(prototype->block);
	  mkcl_object fname = VV[fname_location];
	  /* mkcl_object source = prototype->file; */
	  mkcl_object position = prototype->file_position;
	  int narg = prototype->narg;
	  mkcl_object * anchor = prototype->anchor;
	  mkcl_index nb_fun_refs = prototype->nb_fun_refs;
	  mkcl_object * fun_ref_sym_locs = prototype->fun_ref_syms;
	  mkcl_object cfun
	    = (narg < 0)
	    ? mkcl_make_cfun_va(env, prototype->f.entry, fname, block, anchor)
	    : mkcl_make_cfun(env, (mkcl_objectfn_fixed) prototype->f.entry,
			     fname, block, narg, anchor);
	  mkcl_build_named_cfun_fun_ref_syms(env, cfun, VV, fun_ref_sym_locs, nb_fun_refs);
	  /* Add source file info */
	  if (position != MKCL_MAKE_FIXNUM(-1)) {
	    mkcl_set_function_source_file_info(env, cfun, block->cblock.source, position);
	  }
	  /* VV[location] */
	  block->cblock.cfun_objs[location] = cfun;
	}
    }

    /* Execute top-level code */
    env->function = mk_cl_Cnil; /* signal that we are at toplevel. */
    (*entry_point)(env, mk_cl_Cnil, filename);

    if (VVtemp) {
      block->cblock.temp_data = NULL;
      block->cblock.temp_data_size = 0;
      mkcl_dealloc(env, VVtemp);
    }
    mkcl_bds_unwind1(env);
  } MKCL_UNWIND_PROTECT_EXIT {
    if (in != MKCL_OBJNULL)
      mk_cl_close(env, 1,in);

  } MKCL_UNWIND_PROTECT_END;

  {
    mkcl_object missing_packages = mk_cl_Cnil;
    volatile bool locked = false;

    MKCL_UNWIND_PROTECT_BEGIN(env) {
      MKCL_LIBC_NO_INTR(env, (MKCL_PACKAGE_LIST_LOCK(), locked = true));
      mkcl_object x = mkcl_core.packages_to_be_created;
      mkcl_loop_for_on(env, x) {
        mkcl_object pkg_name = MKCL_CAR(MKCL_CAR(x));
        if ( mk_cl_Cnil == mk_cl_assoc(env, 2, pkg_name, old_ptbc) )
          { /* we get here if pkg_name is not in the old a-list. */
            /* it means that the package named by pkg_name
               was referenced between the beginning of this mkcl_read_VV
               and now without ever being properly created.
            */
            missing_packages = MKCL_CONS(env, pkg_name, missing_packages);
          }
      } mkcl_end_loop_for_on;
    } MKCL_UNWIND_PROTECT_EXIT {
      if (locked) MKCL_PACKAGE_LIST_UNLOCK();
    } MKCL_UNWIND_PROTECT_END;
    if (!mkcl_Null(missing_packages))
      mkcl_FEerror(env, "While loading (~A) compiled from (~A),~%The following packages were referenced but do not exist yet: ~A.",
                   3, filename, block->cblock.source, missing_packages);
  }

  return block;
}
