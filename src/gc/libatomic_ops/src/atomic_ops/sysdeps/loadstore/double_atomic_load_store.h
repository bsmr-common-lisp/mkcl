/*
 * Copyright (c) 2004 Hewlett-Packard Development Company, L.P.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

/* Definitions for architectures on which MK_AO_double_t loads and stores  */
/* are atomic (either for suitably aligned data only or for any legal   */
/* alignment).                                                          */

MK_AO_INLINE MK_AO_double_t
MK_AO_double_load(const volatile MK_AO_double_t *addr)
{
  MK_AO_double_t result;

# ifdef MK_AO_ACCESS_double_CHECK_ALIGNED
    assert(((size_t)addr & (sizeof(MK_AO_double_t) - 1)) == 0);
# endif
  /* Cast away the volatile in case it adds fence semantics.  */
  result.MK_AO_whole = ((const MK_AO_double_t *)addr)->MK_AO_whole;
  return result;
}
#define MK_AO_HAVE_double_load

MK_AO_INLINE void
MK_AO_double_store(volatile MK_AO_double_t *addr, MK_AO_double_t new_val)
{
# ifdef MK_AO_ACCESS_double_CHECK_ALIGNED
    assert(((size_t)addr & (sizeof(MK_AO_double_t) - 1)) == 0);
# endif
  ((MK_AO_double_t *)addr)->MK_AO_whole = new_val.MK_AO_whole;
}
#define MK_AO_HAVE_double_store
