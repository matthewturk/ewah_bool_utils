"""
Simple integrators for the radiative transfer equation



"""

#-----------------------------------------------------------------------------
# Copyright (c) 2013, yt Development Team.
#
# Distributed under the terms of the Modified BSD License.
#
# The full license is in the file COPYING.txt, distributed with this software.
#-----------------------------------------------------------------------------

import numpy as np
cimport numpy as np
cimport cython
from libc.stdlib cimport malloc, free
from fp_utils cimport fclip, i64clip
from libc.math cimport copysign
from yt.utilities.exceptions import YTDomainOverflow

DEF ORDER_MAX=20
DEF INDEX_MAX_64=2097151
DEF XSHIFT=2
DEF YSHIFT=1
DEF ZSHIFT=0

cdef extern from "math.h":
    double exp(double x) nogil
    float expf(float x) nogil
    long double expl(long double x) nogil
    double floor(double x) nogil
    double ceil(double x) nogil
    double fmod(double x, double y) nogil
    double log2(double x) nogil
    long int lrint(double x) nogil
    double fabs(double x) nogil

# Finally, miscellaneous routines.

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def find_values_at_point(np.ndarray[np.float64_t, ndim=1] point,
                         np.ndarray[np.float64_t, ndim=2] left_edges,
                         np.ndarray[np.float64_t, ndim=2] right_edges,
                         np.ndarray[np.int32_t, ndim=2] dimensions,
                         field_names, grid_objects):
    # This iterates in order, first to last, and then returns with the first
    # one in which the point is located; this means if you order from highest
    # level to lowest, you will find the correct grid without consulting child
    # masking.  Note also that we will do a few relatively slow operations on
    # strings and whatnot, but they should not be terribly slow.
    cdef int ind[3]
    cdef int gi, fi, nf = len(field_names)
    cdef np.float64_t dds
    cdef np.ndarray[np.float64_t, ndim=3] field
    cdef np.ndarray[np.float64_t, ndim=1] rv = np.zeros(nf, dtype='float64')
    for gi in range(left_edges.shape[0]):
        if not ((left_edges[gi,0] < point[0] < right_edges[gi,0])
            and (left_edges[gi,1] < point[1] < right_edges[gi,1])
            and (left_edges[gi,2] < point[2] < right_edges[gi,2])):
            continue
        # We found our grid!
        for fi in range(3):
            dds = ((right_edges[gi,fi] - left_edges[gi,fi])/
                   (<np.float64_t> dimensions[gi,fi]))
            ind[fi] = <int> ((point[fi] - left_edges[gi,fi])/dds)
        grid = grid_objects[gi]
        for fi in range(nf):
            field = grid[field_names[fi]]
            rv[fi] = field[ind[0], ind[1], ind[2]]
        return rv
    raise KeyError

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def obtain_rvec(data):
    # This is just to let the pointers exist and whatnot.  We can't cdef them
    # inside conditionals.
    cdef np.ndarray[np.float64_t, ndim=1] xf
    cdef np.ndarray[np.float64_t, ndim=1] yf
    cdef np.ndarray[np.float64_t, ndim=1] zf
    cdef np.ndarray[np.float64_t, ndim=2] rf
    cdef np.ndarray[np.float64_t, ndim=3] xg
    cdef np.ndarray[np.float64_t, ndim=3] yg
    cdef np.ndarray[np.float64_t, ndim=3] zg
    cdef np.ndarray[np.float64_t, ndim=4] rg
    cdef np.float64_t c[3]
    cdef int i, j, k
    center = data.get_field_parameter("center")
    c[0] = center[0]; c[1] = center[1]; c[2] = center[2]
    if len(data['x'].shape) == 1:
        # One dimensional data
        xf = data['x']
        yf = data['y']
        zf = data['z']
        rf = np.empty((3, xf.shape[0]), 'float64')
        for i in range(xf.shape[0]):
            rf[0, i] = xf[i] - c[0]
            rf[1, i] = yf[i] - c[1]
            rf[2, i] = zf[i] - c[2]
        return rf
    else:
        # Three dimensional data
        xg = data['x']
        yg = data['y']
        zg = data['z']
        rg = np.empty((3, xg.shape[0], xg.shape[1], xg.shape[2]), 'float64')
        for i in range(xg.shape[0]):
            for j in range(xg.shape[1]):
                for k in range(xg.shape[2]):
                    rg[0,i,j,k] = xg[i,j,k] - c[0]
                    rg[1,i,j,k] = yg[i,j,k] - c[1]
                    rg[2,i,j,k] = zg[i,j,k] - c[2]
        return rg

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t graycode(np.int64_t x):
    return x^(x>>1)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t igraycode(np.int64_t x):
    cdef np.int64_t i, j
    if x == 0:
        return x
    m = <np.int64_t> ceil(log2(x)) + 1
    i, j = x, 1
    while j < m:
        i = i ^ (x>>j)
        j += 1
    return i

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t direction(np.int64_t x, np.int64_t n):
    #assert x < 2**n
    if x == 0:
        return 0
    elif x%2 == 0:
        return tsb(x-1, n)%n
    else:
        return tsb(x, n)%n

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t tsb(np.int64_t x, np.int64_t width):
    #assert x < 2**width
    cdef np.int64_t i = 0
    while x&1 and i <= width:
        x = x >> 1
        i += 1
    return i

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t bitrange(np.int64_t x, np.int64_t width,
                         np.int64_t start, np.int64_t end):
    return x >> (width-end) & ((2**(end-start))-1)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t rrot(np.int64_t x, np.int64_t i, np.int64_t width):
    i = i%width
    x = (x>>i) | (x<<width-i)
    return x&(2**width-1)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t lrot(np.int64_t x, np.int64_t i, np.int64_t width):
    i = i%width
    x = (x<<i) | (x>>width-i)
    return x&(2**width-1)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t transform(np.int64_t entry, np.int64_t direction,
                          np.int64_t width, np.int64_t x):
    return rrot((x^entry), direction + 1, width)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t entry(np.int64_t x):
    if x == 0: return 0
    return graycode(2*((x-1)/2))

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t setbit(np.int64_t x, np.int64_t w, np.int64_t i, np.int64_t b):
    if b == 1:
        return x | 2**(w-i-1)
    elif b == 0:
        return x & ~2**(w-i-1)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def spread_bits(np.uint64_t x):
    return spread_64bits_by2(x)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def compact_bits(np.uint64_t x):
    return compact_64bits_by2(x)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def lsz(np.uint64_t v, int stride = 1, int start = 0):
    cdef int c
    c = start
    while ((np.uint64(1) << np.uint64(c)) & np.uint64(v)):
        c += stride
    return c

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def lsb(np.uint64_t v, int stride = 1, int start = 0):
    cdef int c
    c = start
    while (np.uint64(v) << np.uint64(c)) and not ((np.uint64(1) << np.uint64(c)) & np.uint64(v)):
        c += stride
    return c

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def bitwise_addition(np.uint64_t x, np.int64_t y0, 
                     int stride = 1, int start = 0):
    if (y0 == 0): return x
    cdef int end, p, pstart
    cdef list mstr
    cdef np.uint64_t m, y, out
    y = np.uint64(np.abs(y0))
    if (y0 > 0):
        func_ls = lsz
    else:
        func_ls = lsb
    # Continue until all bits added
    p = 0
    out = x
    while (y >> p):
        if (y & (1 << p)): 
            # Get end point
            pstart = start + p*stride
            end = func_ls(out,stride=stride,start=pstart)
            # Create mask
            mstr = (end + 1) * ['0']
            for i in range(pstart,end+1,stride):
                mstr[i] = '1'
                m = int(''.join(mstr[::-1]), 2)
            # Invert portion in mask
            # print mstr[::-1]
            # print y,p,(pstart,end+1),bin(m),bin(out),bin(~out)
            out = masked_merge_64bit(out, ~out, m)
        # Move to next bit
        p += 1
    return out

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t point_to_hilbert(int order, np.int64_t p[3]):
    cdef np.int64_t h, e, d, l, b, w, i, x
    h = e = d = 0
    for i in range(order):
        l = 0
        for x in range(3):
            b = bitrange(p[3-x-1], order, i, i+1)
            l |= (b<<x)
        l = transform(e, d, 3, l)
        w = igraycode(l)
        e = e ^ lrot(entry(w), d+1, 3)
        d = (d + direction(w, 3) + 1)%3
        h = (h<<3)|w
    return h

#def hilbert_point(dimension, order, h):
#    """
#        Convert an index on the Hilbert curve of the specified dimension and
#        order to a set of point coordinates.
#    """
#    #    The bit widths in this function are:
#    #        p[*]  - order
#    #        h     - order*dimension
#    #        l     - dimension
#    #        e     - dimension
#    hwidth = order*dimension
#    e, d = 0, 0
#    p = [0]*dimension
#    for i in range(order):
#        w = utils.bitrange(h, hwidth, i*dimension, i*dimension+dimension)
#        l = utils.graycode(w)
#        l = itransform(e, d, dimension, l)
#        for j in range(dimension):
#            b = utils.bitrange(l, dimension, j, j+1)
#            p[j] = utils.setbit(p[j], order, i, b)
#        e = e ^ utils.lrot(entry(w), d+1, dimension)
#        d = (d + direction(w, dimension) + 1)%dimension
#    return p

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef void hilbert_to_point(int order, np.int64_t h, np.int64_t *p):
    cdef np.int64_t hwidth, e, d, w, l, b
    cdef int i, j
    hwidth = 3 * order
    e = d = p[0] = p[1] = p[2] = 0
    for i in range(order):
        w = bitrange(h, hwidth, i*3, i*3+3)
        l = graycode(w)
        l = lrot(l, d +1, 3)^e
        for j in range(3):
            b = bitrange(l, 3, j, j+1)
            p[j] = setbit(p[j], order, i, b)
        e = e ^ lrot(entry(w), d+1, 3)
        d = (d + direction(w, 3) + 1)%3

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_hilbert_indices(int order, np.ndarray[np.int64_t, ndim=2] left_index):
    # This is inspired by the scurve package by user cortesi on GH.
    cdef int i
    cdef np.int64_t p[3]
    cdef np.ndarray[np.int64_t, ndim=1] hilbert_indices
    hilbert_indices = np.zeros(left_index.shape[0], 'int64')
    for i in range(left_index.shape[0]):
        p[0] = left_index[i, 0]
        p[1] = left_index[i, 1]
        p[2] = left_index[i, 2]
        hilbert_indices[i] = point_to_hilbert(order, p)
    return hilbert_indices

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_hilbert_points(int order, np.ndarray[np.int64_t, ndim=1] indices):
    # This is inspired by the scurve package by user cortesi on GH.
    cdef int i, j
    cdef np.int64_t p[3]
    cdef np.ndarray[np.int64_t, ndim=2] positions
    positions = np.zeros((indices.shape[0], 3), 'int64')
    for i in range(indices.shape[0]):
        hilbert_to_point(order, indices[i], p)
        for j in range(3):
            positions[i, j] = p[j]
    return positions

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.uint64_t point_to_morton(np.uint64_t p[3]):
    # Weird indent thing going on... also, should this reference the pxd func?
    return encode_morton_64bit(p[0],p[1],p[2])
    
@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef void morton_to_point(np.uint64_t mi, np.uint64_t *p):
    decode_morton_64bit(mi,p)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_index(np.ndarray[np.uint64_t, ndim=1] left_index):
    cdef int j
    cdef np.uint64_t morton_index
    cdef np.uint64_t p[3]
    for j in range(3):
        if left_index[j] >= INDEX_MAX_64:
            raise ValueError("Point exceeds max ({}) ".format(INDEX_MAX_64)+
                             "for 64bit interleave.")
        p[j] = left_index[j]
    morton_index = point_to_morton(p)
    return morton_index

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_indices(np.ndarray[np.uint64_t, ndim=2] left_index):
    cdef np.int64_t i
    cdef int j
    cdef np.ndarray[np.uint64_t, ndim=1] morton_indices
    cdef np.uint64_t p[3]
    morton_indices = np.zeros(left_index.shape[0], 'uint64')
    for i in range(left_index.shape[0]):
        for j in range(3):
            if left_index[i, j] >= INDEX_MAX_64:
                raise ValueError("Point exceeds max ({}) ".format(INDEX_MAX_64)+
                                 "for 64bit interleave.")
            p[j] = left_index[i, j]
        morton_indices[i] = point_to_morton(p)
    return morton_indices

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_indices_unravel(np.ndarray[np.uint64_t, ndim=1] left_x,
                               np.ndarray[np.uint64_t, ndim=1] left_y,
                               np.ndarray[np.uint64_t, ndim=1] left_z):
    cdef np.int64_t i
    cdef np.ndarray[np.uint64_t, ndim=1] morton_indices
    cdef np.uint64_t p[3]
    morton_indices = np.zeros(left_x.shape[0], 'uint64')
    for i in range(left_x.shape[0]):
        p[0] = left_x[i]
        p[1] = left_y[i]
        p[2] = left_z[i]
        for j in range(3):
            if p[j] >= INDEX_MAX_64:
                raise ValueError("Point exceeds max ({}) ".format(INDEX_MAX_64)+
                                 "for 64 bit interleave.")
        morton_indices[i] = point_to_morton(p)
    return morton_indices

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_points(np.ndarray[np.uint64_t, ndim=1] indices):
    # This is inspired by the scurve package by user cortesi on GH.
    cdef int i, j
    cdef np.uint64_t p[3]
    cdef np.ndarray[np.uint64_t, ndim=2] positions
    positions = np.zeros((indices.shape[0], 3), 'uint64')
    for i in range(indices.shape[0]):
        morton_to_point(indices[i], p)
        for j in range(3):
            positions[i, j] = p[j]
    return positions

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def morton_neighbor(np.ndarray[np.uint64_t,ndim=1] p, list dim_list, list num_list, 
                    int order = ORDER_MAX, periodic = False):
    cdef np.int64_t x
    cdef np.uint64_t imax
    cdef np.uint64_t p1[3]
    cdef int j, dim, num
    for j in range(3):
        p1[j] = np.uint64(p[j])
    for dim,num in zip(dim_list,num_list):
        x = np.int64(p[dim]) + num
        imax = np.uint64(1 << order)
        if (x < 0):
            if periodic:
                p1[dim] = np.uint64(imax - (abs(x) % imax))
            else:
                return np.int64(-1)
        elif (x > imax):
            if periodic:
                p1[dim] = np.uint64(x % imax)
            else:
                return np.int64(-1)
        else:
            p1[dim] = np.uint64(x)
    return np.int64(point_to_morton(p1))

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_neighbors(np.ndarray[np.uint64_t,ndim=1] mi,
                         int order = ORDER_MAX, periodic = False):
    """Returns array of neighboring morton indices"""
    cdef int i, j, k, l, n
    cdef np.ndarray[np.uint64_t, ndim=2] p
    cdef np.int64_t nmi
    cdef np.ndarray[np.uint64_t, ndim=1] mi_neighbors
    p = get_morton_points(mi)
    mi_neighbors = np.zeros(26*mi.shape[0], 'uint64')
    n = 0
    for i in range(mi.shape[0]):
        for j in range(3):
            # +1 in dimension j
            nmi = morton_neighbor(p[i,:],[j],[+1],order=order,periodic=periodic)
            if nmi > 0:
                mi_neighbors[n] = np.uint64(nmi)
                n+=1
                # +/- in dimension k
                for k in range(j+1,3):
                    # +1 in dimension k
                    nmi = morton_neighbor(p[i,:],[j,k],[+1,+1],order=order,periodic=periodic)
                    if nmi > 0:
                        mi_neighbors[n] = np.uint64(nmi)
                        n+=1
                        # +/- in dimension l
                        for l in range(k+1,3):
                            nmi = morton_neighbor(p[i,:],[j,k,l],[+1,+1,+1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                            nmi = morton_neighbor(p[i,:],[j,k,l],[+1,+1,-1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                    # -1 in dimension k
                    nmi = morton_neighbor(p[i,:],[j,k],[+1,-1],order=order,periodic=periodic)
                    if nmi > 0:
                        mi_neighbors[n] = np.uint64(nmi)
                        n+=1
                        # +/- in dimension l
                        for l in range(k+1,3):
                            nmi = morton_neighbor(p[i,:],[j,k,l],[+1,-1,+1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                            nmi = morton_neighbor(p[i,:],[j,k,l],[+1,-1,-1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
            # -1 in dimension j
            nmi = morton_neighbor(p[i,:],[j],[-1],order=order,periodic=periodic)
            if nmi > 0:
                mi_neighbors[n] = np.uint64(nmi)
                n+=1
                # +/- in dimension k
                for k in range(j+1,3):
                    # +1 in dimension k
                    nmi = morton_neighbor(p[i,:],[j,k],[-1,+1],order=order,periodic=periodic)
                    if nmi > 0:
                        mi_neighbors[n] = np.uint64(nmi)
                        n+=1
                        # +/- in dimension l
                        for l in range(k+1,3):
                            nmi = morton_neighbor(p[i,:],[j,k,l],[-1,+1,+1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                            nmi = morton_neighbor(p[i,:],[j,k,l],[-1,+1,-1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                    # -1 in dimension k
                    nmi = morton_neighbor(p[i,:],[j,k],[-1,-1],order=order,periodic=periodic)
                    if nmi > 0:
                        mi_neighbors[n] = np.uint64(nmi)
                        n+=1
                        # +/- in dimension l
                        for l in range(k+1,3):
                            nmi = morton_neighbor(p[i,:],[j,k,l],[-1,-1,+1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
                            nmi = morton_neighbor(p[i,:],[j,k,l],[-1,-1,-1],order=order,periodic=periodic)
                            if nmi > 0:
                                mi_neighbors[n] = np.uint64(nmi)
                                n+=1
    return np.resize(mi_neighbors,(n,))
    # mi_neighbors.resize(k,refcheck=False)
    # return mi_neighbors

ctypedef fused anyfloat:
    np.float32_t
    np.float64_t

def ifrexp_cy(np.float64_t x):
    cdef np.int64_t e, m
    m = ifrexp(x, &e)
    return m,e

def msdb_cy(np.int64_t a, np.int64_t b):
    return msdb(a,b)

def msdb_cy(np.int64_t a, np.int64_t b):
    return msdb(a,b)

def xor_msb_cy(np.float64_t a, np.float64_t b):
    return xor_msb(a,b)

def morton_qsort_swap(np.ndarray[np.uint64_t, ndim=1] ind,
                      np.uint64_t a, np.uint64_t b):
    # http://www.geeksforgeeks.org/iterative-quick-sort/
    cdef np.int64_t t = ind[a]
    ind[a] = ind[b]
    ind[b] = t

def morton_qsort_partition(np.ndarray[anyfloat, ndim=2] pos,
                           np.int64_t l, np.int64_t h,
                           np.ndarray[np.uint64_t, ndim=1] ind,
                           use_loop = False):
    # Initialize
    cdef int k
    cdef np.int64_t i, j
    cdef np.float64_t ppos[3]
    cdef np.float64_t ipos[3]
    cdef np.uint64_t done, pivot
    if use_loop:
        # http://www.geeksforgeeks.org/iterative-quick-sort/
        # A bit slower
        # Set starting point & pivot
        i = (l - 1)
        for k in range(3):
            ppos[k] = pos[ind[h],k]
        # Loop over array moving ind for points smaller than pivot to front
        for j in range(l, h):
            for k in range(3):
                ipos[k] = pos[ind[j],k]
            if compare_floats_morton(ipos,ppos):
                i+=1
                morton_qsort_swap(ind,i,j)
        # Swap the pivot to the midpoint in the partition
        i+=1
        morton_qsort_swap(ind,i,h)
        return i
    else:
        # Set starting point & pivot
        i = l-1
        j = h
        done = 0
        pivot = ind[h]
        for k in range(3):
            ppos[k] = pos[pivot,k]
        # Loop until entire array processed
        while not done:
            # Process bottom
            while not done:
                i+=1
                if i == j:
                    done = 1
                    break
                for k in range(3):
                    ipos[k] = pos[ind[i],k]
                if compare_floats_morton(ppos,ipos):
                    ind[j] = ind[i]
                    break
            # Process top
            while not done:
                j-=1
                if j == i:
                    done = 1
                    break
                for k in range(3):
                    ipos[k] = pos[ind[j],k]
                if compare_floats_morton(ipos,ppos):
                    ind[i] = ind[j]
                    break
        ind[j] = pivot
    return j

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def morton_qsort_recursive(np.ndarray[anyfloat, ndim=2] pos,
                           np.int64_t l, np.int64_t h,
                           np.ndarray[np.uint64_t, ndim=1] ind,
                           use_loop = False):
    # http://www.geeksforgeeks.org/iterative-quick-sort/
    cdef np.int64_t p
    if (l < h):
        p = morton_qsort_partition(pos, l, h, ind, use_loop=use_loop)
        morton_qsort_recursive(pos, l, p-1, ind, use_loop=use_loop)
        morton_qsort_recursive(pos, p+1, h, ind, use_loop=use_loop)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def morton_qsort_iterative(np.ndarray[anyfloat, ndim=2] pos,
                           np.int64_t l, np.int64_t h,
                           np.ndarray[np.uint64_t, ndim=1] ind,
                           use_loop = False):
    # http://www.geeksforgeeks.org/iterative-quick-sort/
    # Auxillary stack
    cdef np.ndarray[np.int64_t, ndim=1] stack = np.zeros(h-l+1, dtype=np.int64)
    cdef np.int64_t top = -1
    cdef np.int64_t p
    top+=1
    stack[top] = l
    top+=1
    stack[top] = h
    # Pop from stack until it's empty
    while (top >= 0):
        # Get next set
        h = stack[top]
        top-=1
        l = stack[top]
        top-=1
        # Partition
        p = morton_qsort_partition(pos, l, h, ind, use_loop=use_loop)
        # Add left partition to the stack
        if (p-1) > l:
            top+=1
            stack[top] = l
            top+=1
            stack[top] = p - 1
        # Add right partition to the stack
        if (p+1) < h:
            top+=1
            stack[top] = p + 1
            top+=1
            stack[top] = h
            
@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def morton_qsort(np.ndarray[anyfloat, ndim=2] pos,
                 np.int64_t l, np.int64_t h,
                 np.ndarray[np.uint64_t, ndim=1] ind,
                 recursive = False,
                 use_loop = False):
    #get_morton_argsort1(pos,l,h,ind)
    if recursive:
        morton_qsort_recursive(pos,l,h,ind,use_loop=use_loop)
    else:
        morton_qsort_iterative(pos,l,h,ind,use_loop=use_loop)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def get_morton_argsort1(np.ndarray[anyfloat, ndim=2] pos, 
                        np.int64_t start, np.int64_t end,
                        np.ndarray[np.uint64_t, ndim=1] ind):
    # Return if only one position selected
    if start >= end: return
    # Initialize
    cdef np.int64_t top 
    top = morton_qsort_partition(pos,start,end,ind)
    # Do remaining parts on either side of pivot, sort side first
    if (top-1-start < end-(top+1)):
        get_morton_argsort1(pos,start,top-1,ind)
        get_morton_argsort1(pos,top+1,end,ind)
    else:
        get_morton_argsort1(pos,top+1,end,ind)
        get_morton_argsort1(pos,start,top-1,ind)
    return

def compare_morton(np.ndarray[anyfloat, ndim=1] p0, np.ndarray[anyfloat, ndim=1] q0):
    cdef np.float64_t p[3]
    cdef np.float64_t q[3]
    # cdef np.int64_t iep,ieq,imp,imq
    cdef int j
    for j in range(3):
        p[j] = p0[j]
        q[j] = q0[j]
        # imp = ifrexp(p[j],&iep)
        # imq = ifrexp(q[j],&ieq)
        # print j,p[j],q[j],xor_msb(p[j],q[j]),'m=',imp,imq,'e=',iep,ieq
    return compare_floats_morton(p,q)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
cdef np.int64_t position_to_morton(np.ndarray[anyfloat, ndim=1] pos_x,
                        np.ndarray[anyfloat, ndim=1] pos_y,
                        np.ndarray[anyfloat, ndim=1] pos_z,
                        np.float64_t dds[3], np.float64_t DLE[3],
                        np.float64_t DRE[3],
                        np.ndarray[np.uint64_t, ndim=1] ind,
                        int filter):
    cdef np.uint64_t mi
    cdef np.uint64_t ii[3]
    cdef np.float64_t p[3]
    cdef np.int64_t i, j, use
    cdef np.uint64_t DD[3]
    cdef np.uint64_t FLAG = ~(<np.uint64_t>0)
    for i in range(3):
        DD[i] = <np.uint64_t> ((DRE[i] - DLE[i]) / dds[i])
    for i in range(pos_x.shape[0]):
        use = 1
        p[0] = <np.float64_t> pos_x[i]
        p[1] = <np.float64_t> pos_y[i]
        p[2] = <np.float64_t> pos_z[i]
        for j in range(3):
            if p[j] < DLE[j] or p[j] > DRE[j]:
                if filter == 1:
                    # We only allow 20 levels, so this is inaccessible
                    use = 0
                    break
                return i
            ii[j] = <np.uint64_t> ((p[j] - DLE[j])/dds[j])
            ii[j] = i64clip(ii[j], 0, DD[j] - 1)
        if use == 0:
            ind[i] = FLAG
            continue
        ind[i] = encode_morton_64bit(ii[0],ii[1],ii[2])
    return pos_x.shape[0]

def compute_morton(np.ndarray pos_x, np.ndarray pos_y, np.ndarray pos_z,
                   domain_left_edge, domain_right_edge, filter_bbox = False,
                   order = ORDER_MAX):
    cdef int i
    cdef int filter
    if filter_bbox:
        filter = 1
    else:
        filter = 0
    cdef np.float64_t dds[3]
    cdef np.float64_t DLE[3]
    cdef np.float64_t DRE[3]
    for i in range(3):
        DLE[i] = domain_left_edge[i]
        DRE[i] = domain_right_edge[i]
        dds[i] = (DRE[i] - DLE[i]) / (1 << order)
    cdef np.ndarray[np.uint64_t, ndim=1] ind
    ind = np.zeros(pos_x.shape[0], dtype="uint64")
    cdef np.int64_t rv
    if pos_x.dtype == np.float32:
        rv = position_to_morton[np.float32_t](
                pos_x, pos_y, pos_z, dds, DLE, DRE, ind,
                filter)
    elif pos_x.dtype == np.float64:
        rv = position_to_morton[np.float64_t](
                pos_x, pos_y, pos_z, dds, DLE, DRE, ind,
                filter)
    else:
        print "Could not identify dtype.", pos_x.dtype
        raise NotImplementedError
    if rv < pos_x.shape[0]:
        mis = (pos_x.min(), pos_y.min(), pos_z.min())
        mas = (pos_x.max(), pos_y.max(), pos_z.max())
        raise YTDomainOverflow(mis, mas,
                               domain_left_edge, domain_right_edge)
    return ind

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def dist(np.ndarray[np.float64_t, ndim=1] p0, np.ndarray[np.float64_t, ndim=1] q0):
    cdef int j
    cdef np.float64_t p[3]
    cdef np.float64_t q[3]
    for j in range(3):
        p[j] = p0[j]
        q[j] = q0[j]
    return euclidean_distance(p,q)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def dist_to_box(np.ndarray[np.float64_t, ndim=1] p,
                np.ndarray[np.float64_t, ndim=1] cbox,
                np.float64_t rbox):
    cdef int j
    cdef np.float64_t d = 0.0
    for j in range(3):
        d+= max((cbox[j]-rbox)-p[j],0.0,p[j]-(cbox[j]+rbox))**2
    return np.sqrt(d)


@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def solution_radius(np.ndarray[np.float64_t, ndim=2] P, int k, np.uint64_t i,
                    np.ndarray[np.uint64_t, ndim=1] idx, int order, 
                    np.ndarray[np.float64_t, ndim=1] DLE,
                    np.ndarray[np.float64_t, ndim=1] DRE):
    c = np.zeros(3, dtype=np.float64)
    return quadtree_box(P[i,:],P[idx[k-1],:],order,DLE,DRE,c)

@cython.cdivision(True)
@cython.boundscheck(False)
@cython.wraparound(False)
def knn_direct(np.ndarray[np.float64_t, ndim=2] P, int k, np.uint64_t i,
               np.ndarray[np.uint64_t, ndim=1] idx, return_dist = False, 
               return_rad = False):
    """Directly compute the k nearest neighbors by sorting on distance.

    Args:
        P (np.ndarray): (N,d) array of points to search sorted by Morton order.
        k (int): number of nearest neighbors to find.
        i (int): index of point that nearest neighbors should be found for.
        idx (np.ndarray): indicies of points from P to be considered.
        return_dist (Optional[bool]): If True, distances to the k nearest 
            neighbors are also returned (in order of proximity). 
            (default = False) 
        return_rad (Optional[bool]): If True, distance to farthest nearest 
            neighbor is also returned. This is set to False if return_dist is 
            True. (default = False)

    Returns: 
        np.ndarray: Indicies of k nearest neighbors to point i. 

    """
    cdef int j,m
    #cdef np.ndarray[np.float64_t, ndim=1] dist
    cdef np.ndarray[long, ndim=1] sort_fwd
    cdef np.float64_t ipos[3]
    cdef np.float64_t jpos[3]
    dist = np.zeros(len(idx),dtype=[('dist','float64'),('ind','int64')])
    for m in range(3): ipos[m] = P[i,m]
    for j in range(len(idx)):
        for m in range(3): jpos[m] = P[idx[j],m]
        dist['dist'][j] = euclidean_distance(ipos,jpos)
        dist['ind'][j] = idx[j]
    # TODO: this can be done more efficiently for just appending a few
    # values. Possibly sort addition first and then make a collective pass
    sort_fwd = np.argsort(dist,order=('dist','ind'))[:k]#.astype(np.uint64)
    if return_dist:
        return idx[sort_fwd],dist['dist'][sort_fwd]
    elif return_rad:
        return idx[sort_fwd],dist['dist'][sort_fwd][k-1]
    else:
        return idx[sort_fwd]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def quadtree_box(np.ndarray[np.float64_t, ndim=1] p, 
                 np.ndarray[np.float64_t, ndim=1] q, int order, 
                 np.ndarray[np.float64_t, ndim=1] DLE,
                 np.ndarray[np.float64_t, ndim=1] DRE,
                 np.ndarray[np.float64_t, ndim=1] c):
    # Declare & transfer values to ctypes
    cdef int j
    cdef np.float64_t ppos[3]
    cdef np.float64_t qpos[3]
    cdef np.float64_t rbox
    cdef np.float64_t cbox[3]
    cdef np.float64_t DLE1[3]
    cdef np.float64_t DRE1[3]
    for j in range(3):
        ppos[j] = p[j]
        qpos[j] = q[j]
        DLE1[j] = DLE[j]
        DRE1[j] = DRE[j] 
    # Get smallest box containing p & q
    rbox = smallest_quadtree_box(ppos,qpos,order,DLE1,DRE1,
                                 &cbox[0],&cbox[1],&cbox[2])
    # Transfer values to python array
    for j in range(3):
        c[j] = cbox[j]
    return rbox
   

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def csearch_morton(np.ndarray[np.float64_t, ndim=2] P, int k, np.uint64_t i,
                   np.ndarray[np.uint64_t, ndim=1] Ai, 
                   np.uint64_t l, np.uint64_t h, int order,
                   np.ndarray[np.float64_t, ndim=1] DLE,
                   np.ndarray[np.float64_t, ndim=1] DRE, int nu = 4):
    """Expand search concentrically to determine set of k nearest neighbors for 
    point i. 

    Args: 
        P (np.ndarray): (N,d) array of points to search sorted by Morton order. 
        k (int): number of nearest neighbors to find. 
        i (int): index of point that nearest neighbors should be found for. 
        Ai (np.ndarray): (N,k) array of partial nearest neighbor indices. 
        l (int): index of lowest point to consider in addition to Ai. 
        h (int): index of highest point to consider in addition to Ai. 
        order (int): Maximum depth that Morton order quadtree should reach. 
        DLE (np.float64[3]): 3 floats defining domain lower bounds in each dim.
        DRE (np.float64[3]): 3 floats defining domain upper bounds in each dim.
        nu (int): minimum number of points before a direct knn search is 
            performed. (default = 4) 

    Returns: 
        np.ndarray: (N,k) array of nearest neighbor indices. 

    Raises: 
        ValueError: If l<i<h. l and h must be on the same side of i. 

    """
    cdef int j
    cdef np.uint64_t m
    # Make sure that h and l are both larger/smaller than i
    if (l < i) and (h > i):
        raise ValueError("Both l and h must be on the same side of i.")
    m = np.uint64((h + l)/2)
    # New range is small enough to consider directly 
    if (h-l) < nu:
        if m > i:
            return knn_direct(P,k,i,np.hstack((Ai,np.arange(l,h+1,dtype=np.uint64))))
        else:
            return knn_direct(P,k,i,np.hstack((np.arange(l,h+1,dtype=np.uint64),Ai)))
    # Add middle point
    if m > i:
        Ai,rad_Ai = knn_direct(P,k,i,np.hstack((Ai,m)).astype(np.uint64),return_rad=True)
    else:
        Ai,rad_Ai = knn_direct(P,k,i,np.hstack((m,Ai)).astype(np.uint64),return_rad=True)
    cbox_sol = np.zeros(3,dtype=np.float64)
    rbox_sol = quadtree_box(P[i,:],P[Ai[k-1],:],order,DLE,DRE,cbox_sol)
    # Return current solution if hl box is outside current solution's box
    # Uses actual box
    cbox_hl = np.zeros(3,dtype=np.float64)
    rbox_hl = quadtree_box(P[l,:],P[h,:],order,DLE,DRE,cbox_hl)
    if dist_to_box(cbox_sol,cbox_hl,rbox_hl) >= 1.5*rbox_sol:
        print '{} outside: rad = {}, rbox = {}, dist = {}'.format(m,rad_Ai,rbox_sol,dist_to_box(P[i,:],cbox_hl,rbox_hl))
        return Ai
    # Expand search to lower/higher indicies as needed 
    if i < m: # They are already sorted...
        Ai = csearch_morton(P,k,i,Ai,l,m-1,order,DLE,DRE,nu=nu)
        if compare_morton(P[m,:],P[i,:]+dist(P[i,:],P[Ai[k-1],:])):
            Ai = csearch_morton(P,k,i,Ai,m+1,h,order,DLE,DRE,nu=nu)
    else:
        Ai = csearch_morton(P,k,i,Ai,m+1,h,order,DLE,DRE,nu=nu)
        if compare_morton(P[i,:]-dist(P[i,:],P[Ai[k-1],:]),P[m,:]):
            Ai = csearch_morton(P,k,i,Ai,l,m-1,order,DLE,DRE,nu=nu)
    return Ai


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def knn_morton(np.ndarray[np.float64_t, ndim=2] P0, int k, np.uint64_t i0,
               float c = 1.0, int nu = 4, issorted = False, int order = ORDER_MAX, 
               np.ndarray[np.float64_t, ndim=1] DLE = np.zeros(3,dtype=np.float64),
               np.ndarray[np.float64_t, ndim=1] DRE = np.zeros(3,dtype=np.float64)):
    """Get the indicies of the k nearest neighbors to point i. 
 
    Args: 
        P (np.ndarray): (N,d) array of points to search. 
        k (int): number of nearest neighbors to find for each point in P. 
        i (np.uint64): index of point to find neighbors for.
        c (float): factor determining how many indicies before/after i are used
            in the initial search (i-c*k to i+c*k, default = 1.0) 
        nu (int): minimum number of points before a direct knn search is 
            performed. (default = 4) 
        issorted (Optional[bool]): if True, P is assumed to be sorted already 
            according to Morton order. 
        order (int): Maximum depth that Morton order quadtree should reach. 
            If not provided, ORDER_MAX is used. 
        DLE (np.ndarray): (d,) array of domain lower bounds in each dimension. 
            If not provided, this is determined from the points. 
        DRE (np.ndarray): (d,) array of domain upper bounds in each dimension. 
            If not provided, this is determined from the points. 

    Returns: 
        np.ndarray: (N,k) indicies of k nearest neighbors for each point in P.
"""
    cdef int j
    cdef np.uint64_t i
    cdef np.int64_t N = P0.shape[0]
    cdef np.ndarray[np.float64_t, ndim=2] P
    cdef np.ndarray[np.uint64_t, ndim=1] sort_fwd = np.arange(N,dtype=np.uint64)
    cdef np.ndarray[np.uint64_t, ndim=1] sort_rev = np.arange(N,dtype=np.uint64)
    cdef np.ndarray[np.uint64_t, ndim=1] Ai
    cdef np.int64_t idxmin, idxmax, u, l, I
    # Sort if necessary
    if issorted:
        P = P0
        i = i0
    else:
        morton_qsort(P0,0,N-1,sort_fwd)
        sort_rev = np.argsort(sort_fwd).astype(np.uint64)
        P = P0[sort_fwd,:]
        i = sort_rev[i0]
    # Check domain and set if singular
    for j in range(3):
        if DLE[j] == DRE[j]: 
            DLE[j] = min(P[:,j])
            DRE[j] = max(P[:,j])
    # Get initial guess bassed on position in z-order
    idxmin = <np.int64_t>max(i-c*k, 0)
    idxmax = <np.int64_t>min(i+c*k, N-1)
    Ai = np.hstack((np.arange(idxmin,i,dtype=np.uint64),
                    np.arange(i+1,idxmax+1,dtype=np.uint64)))
    Ai,rad_Ai = knn_direct(P,k,i,Ai,return_rad=True)
    # Get radius of solution
    cbox_Ai = np.zeros(3,dtype=np.float64)
    rbox_Ai = quadtree_box(P[i,:],P[Ai[k-1],:],order,DLE,DRE,cbox_Ai)
    rad_Ai = rbox_Ai
    # Extend upper bound to match lower bound
    if idxmax < (N-1):
        if compare_morton(P[i,:]+rad_Ai,P[idxmax,:]):
            u = i
        else:
            I = 1
            while (idxmax+(2**I) < N) and compare_morton(P[idxmax+(2**I),:],P[i,:]+rad_Ai):
                I+=1
            u = min(idxmax+(2**I),N-1)
            Ai = csearch_morton(P,k,i,Ai,min(idxmax+1,N-1),u,order,DLE,DRE,nu=nu)
    else:
        u = idxmax
    # Extend lower bound to match upper bound
    if idxmin > 0:
        if compare_morton(P[idxmin,:],P[i,:]-rad_Ai):
            l = i
        else:
            I = 1
            while (idxmin-(2**I) >= 0) and compare_morton(P[i,:]-rad_Ai,P[idxmin-(2**I),:]):
                I+=1
            l = max(idxmin-(2**I),0)
            Ai = csearch_morton(P,k,i,Ai,l,max(idxmin-1,0),order,DLE,DRE,nu=nu)
    else:
        l = idxmin
    # Return indices of neighbors in the correct order
    if issorted:
        return Ai
    else:
        return sort_fwd[Ai]

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
def obtain_rv_vec(data):
    # This is just to let the pointers exist and whatnot.  We can't cdef them
    # inside conditionals.
    cdef np.ndarray[np.float64_t, ndim=1] vxf
    cdef np.ndarray[np.float64_t, ndim=1] vyf
    cdef np.ndarray[np.float64_t, ndim=1] vzf
    cdef np.ndarray[np.float64_t, ndim=2] rvf
    cdef np.ndarray[np.float64_t, ndim=3] vxg
    cdef np.ndarray[np.float64_t, ndim=3] vyg
    cdef np.ndarray[np.float64_t, ndim=3] vzg
    cdef np.ndarray[np.float64_t, ndim=4] rvg
    cdef np.float64_t bv[3]
    cdef int i, j, k
    bulk_velocity = data.get_field_parameter("bulk_velocity")
    if bulk_velocity == None:
        bulk_velocity = np.zeros(3)
    bv[0] = bulk_velocity[0]; bv[1] = bulk_velocity[1]; bv[2] = bulk_velocity[2]
    if len(data['velocity_x'].shape) == 1:
        # One dimensional data
        vxf = data['velocity_x'].astype("float64")
        vyf = data['velocity_y'].astype("float64")
        vzf = data['velocity_z'].astype("float64")
        rvf = np.empty((3, vxf.shape[0]), 'float64')
        for i in range(vxf.shape[0]):
            rvf[0, i] = vxf[i] - bv[0]
            rvf[1, i] = vyf[i] - bv[1]
            rvf[2, i] = vzf[i] - bv[2]
        return rvf
    else:
        # Three dimensional data
        vxg = data['velocity_x'].astype("float64")
        vyg = data['velocity_y'].astype("float64")
        vzg = data['velocity_z'].astype("float64")
        rvg = np.empty((3, vxg.shape[0], vxg.shape[1], vxg.shape[2]), 'float64')
        for i in range(vxg.shape[0]):
            for j in range(vxg.shape[1]):
                for k in range(vxg.shape[2]):
                    rvg[0,i,j,k] = vxg[i,j,k] - bv[0]
                    rvg[1,i,j,k] = vyg[i,j,k] - bv[1]
                    rvg[2,i,j,k] = vzg[i,j,k] - bv[2]
        return rvg

cdef struct PointSet
cdef struct PointSet:
    int count
    # First index is point index, second is xyz
    np.float64_t points[3][3]
    PointSet *next

cdef inline void get_intersection(np.float64_t p0[3], np.float64_t p1[3],
                                  int ax, np.float64_t coord, PointSet *p):
    cdef np.float64_t vec[3]
    cdef np.float64_t t
    for j in range(3):
        vec[j] = p1[j] - p0[j]
    t = (coord - p0[ax])/vec[ax]
    # We know that if they're on opposite sides, it has to intersect.  And we
    # won't get called otherwise.
    for j in range(3):
        p.points[p.count][j] = p0[j] + vec[j] * t
    p.count += 1

def triangle_plane_intersect(int ax, np.float64_t coord,
                             np.ndarray[np.float64_t, ndim=3] triangles):
    cdef np.float64_t p0[3]
    cdef np.float64_t p1[3]
    cdef np.float64_t p2[3]
    cdef np.float64_t p3[3]
    cdef int i, j, k, count, i0, i1, i2, ntri, nlines
    nlines = 0
    ntri = triangles.shape[0]
    cdef PointSet *first
    cdef PointSet *last
    cdef PointSet *points
    first = last = points = NULL
    for i in range(ntri):
        count = 0
        # Now for each line segment (01, 12, 20) we check to see how many cross
        # the coordinate.
        for j in range(3):
            p3[j] = copysign(1.0, triangles[i, j, ax] - coord)
        if p3[0] * p3[1] < 0: count += 1
        if p3[1] * p3[2] < 0: count += 1
        if p3[2] * p3[0] < 0: count += 1
        if count == 2:
            nlines += 1
        elif count == 3:
            nlines += 2
        else:
            continue
        points = <PointSet *> malloc(sizeof(PointSet))
        points.count = 0
        points.next = NULL
        if p3[0] * p3[1] < 0:
            for j in range(3):
                p0[j] = triangles[i, 0, j]
                p1[j] = triangles[i, 1, j]
            get_intersection(p0, p1, ax, coord, points)
        if p3[1] * p3[2] < 0:
            for j in range(3):
                p0[j] = triangles[i, 1, j]
                p1[j] = triangles[i, 2, j]
            get_intersection(p0, p1, ax, coord, points)
        if p3[2] * p3[0] < 0:
            for j in range(3):
                p0[j] = triangles[i, 2, j]
                p1[j] = triangles[i, 0, j]
            get_intersection(p0, p1, ax, coord, points)
        if last != NULL:
            last.next = points
        if first == NULL:
            first = points
        last = points
    points = first
    cdef np.ndarray[np.float64_t, ndim=3] line_segments
    line_segments = np.empty((nlines, 2, 3), dtype="float64")
    k = 0
    while points != NULL:
        for j in range(3):
            line_segments[k, 0, j] = points.points[0][j]
            line_segments[k, 1, j] = points.points[1][j]
        k += 1
        if points.count == 3:
            for j in range(3):
                line_segments[k, 0, j] = points.points[1][j]
                line_segments[k, 1, j] = points.points[2][j]
            k += 1
        last = points
        points = points.next
        free(last)
    return line_segments
