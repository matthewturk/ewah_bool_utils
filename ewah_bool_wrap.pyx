"""
Wrapper for EWAH Bool Array: https://github.com/lemire/EWAHBoolArray



"""

#-----------------------------------------------------------------------------
# Copyright (c) 2013, yt Development Team.
#
# Distributed under the terms of the Modified BSD License.
#
# The full license is in the file COPYING.txt, distributed with this software.
#-----------------------------------------------------------------------------

from libcpp.map cimport map
from libcpp.vector cimport vector
from libcpp.pair cimport pair
from libcpp.algorithm cimport sort
from yt.utilities.lib.ewah_bool_array cimport \
    ewah_map, ewah_bool_array, sstream
from cython.operator cimport dereference, preincrement
import numpy as np

cdef extern from "<algorithm>" namespace "std" nogil:
    Iter unique[Iter](Iter first, Iter last)

cdef np.uint64_t FLAG = ~(<np.uint64_t>0)

cdef class BoolArrayCollection:

    def __cinit__(self):
        cdef ewah_bool_array *ewah_keys = new ewah_bool_array()
        cdef ewah_bool_array *ewah_refn = new ewah_bool_array()
        cdef ewah_bool_array *ewah_coar = new ewah_bool_array()
        cdef ewah_map *ewah_coll = new ewah_map()
        self.ewah_keys = <void *> ewah_keys
        self.ewah_refn = <void *> ewah_refn
        self.ewah_coar = <void *> ewah_coar
        self.ewah_coll = <void *> ewah_coll

    cdef void _set(self, np.uint64_t i1, np.uint64_t i2 = FLAG):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef ewah_map *ewah_coll = <ewah_map *> self.ewah_coll
        ewah_keys[0].set(i1)
        # Note the 0 here, for dereferencing
        if i2 != FLAG:
            ewah_refn[0].set(i1)
            ewah_coll[0][i1].set(i2)

    def set(self, i1, i2 = FLAG):
        self._set(i1, i2)

    cdef void _set_coarse(self, np.uint64_t i1):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        ewah_keys[0].set(i1)

    def set_coarse(self, i1):
        return self._set_coarse(i1)

    cdef void _set_refined(self, np.uint64_t i1, np.uint64_t i2):
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef ewah_map *ewah_coll = <ewah_map *> self.ewah_coll
        # Note the 0 here, for dereferencing
        ewah_refn[0].set(i1)
        ewah_coll[0][i1].set(i2)

    def set_refined(self, i1, i2):
        return self._set_refined(i1, i2)
        
    cdef void _set_map(self, np.uint64_t i1, np.uint64_t i2):
        cdef ewah_map *ewah_coll = <ewah_map *> self.ewah_coll
        ewah_coll[0][i1].set(i2)

    def set_map(self, i1, i2):
        self._set_map(i1, i2)

    cdef void _set_refn(self, np.uint64_t i1):
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        ewah_refn[0].set(i1)

    def set_refn(self, i1):
        self._set_refn(i1)

    cdef bint _get(self, np.uint64_t i1, np.uint64_t i2 = FLAG):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef ewah_map *ewah_coll = <ewah_map *> self.ewah_coll
        # Note the 0 here, for dereferencing
        if not ewah_keys[0].get(i1): return 0
        if not ewah_refn[0].get(i1) or (i2 == FLAG): 
            return 1
        return ewah_coll[0][i1].get(i2)

    def get(self, i1, i2 = FLAG):
        return self._get(i1, i2)

    cdef bint _contains(self, np.uint64_t i):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        return ewah_keys[0].get(i)

    def contains(self, np.uint64_t i):
        return self._contains(i)

    cdef bint _isref(self, np.uint64_t i):
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        return ewah_refn[0].get(i)

    def isref(self, np.uint64_t i):
        return self._isref(i)

    cdef void _ewah_coarse(self):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef ewah_bool_array *ewah_coar = <ewah_bool_array *> self.ewah_coar
        ewah_coar[0].reset()
        ewah_keys[0].logicalxor(ewah_refn[0],ewah_coar[0])
        return

    def ewah_coarse(self):
        return self._ewah_coarse()

    cdef int _count_total(self):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef int out
        out = ewah_keys.numberOfOnes()
        return out

    def count_total(self):
        return self._count_total()

    cdef int _count_refined(self):
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef int out
        out = ewah_refn.numberOfOnes()
        return out

    def count_refined(self):
        return self._count_refined()

    cdef int _count_coarse(self):
        self._ewah_coarse()
        cdef ewah_bool_array *ewah_coar = <ewah_bool_array *> self.ewah_coar
        cdef int out
        out = ewah_coar.numberOfOnes()
        return out

    def count_coarse(self):
        return self._count_coarse()

    cdef void _append(self, BoolArrayCollection solf):
        cdef ewah_bool_array *ewah_keys1 = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn1 = <ewah_bool_array *> self.ewah_refn
        cdef map[np.uint64_t, ewah_bool_array] *ewah_coll1 = <map[np.uint64_t, ewah_bool_array] *> self.ewah_coll
        cdef ewah_bool_array *ewah_keys2 = <ewah_bool_array *> solf.ewah_keys
        cdef ewah_bool_array *ewah_refn2 = <ewah_bool_array *> solf.ewah_refn
        cdef map[np.uint64_t, ewah_bool_array] *ewah_coll2 = <map[np.uint64_t, ewah_bool_array] *> solf.ewah_coll
        cdef map[np.uint64_t, ewah_bool_array].iterator it_map1, it_map2
        cdef ewah_bool_array swap, mi1_ewah1, mi1_ewah2
        cdef np.uint64_t nrefn, mi1
        # Keys
        ewah_keys1[0].logicalor(ewah_keys2[0], swap)
        ewah_keys1[0].swap(swap)
        # Refined
        ewah_refn1[0].logicalor(ewah_refn2[0], swap)
        ewah_refn1[0].swap(swap)
        # Map
        it_map = ewah_coll1[0].begin()
        while it_map1 != ewah_coll1[0].end():
            mi1 = dereference(it_map1).first
            mi1_ewah1 = dereference(it_map1).second
            it_map2 = ewah_coll2[0].find(mi1)
            if it_map2 != ewah_coll2[0].end():
                mi1_ewah2 = dereference(it_map2).second
                mi1_ewah1.logicalor(mi1_ewah2, swap)
                mi1_ewah1.swap(swap)
            preincrement(it_map1)

    def append(self, solf):
        return self._append(solf)

    cdef bytes _dumps(self):
        # TODO: write word size
        cdef sstream ss
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef map[np.uint64_t, ewah_bool_array] *ewah_coll = <map[np.uint64_t, ewah_bool_array] *> self.ewah_coll
        cdef map[np.uint64_t, ewah_bool_array].iterator it_map
        cdef np.uint64_t nrefn, mi1
        cdef ewah_bool_array mi1_ewah
        # Write mi1 ewah & refinment ewah
        ewah_keys[0].write(ss,1)
        ewah_refn[0].write(ss,1)
        # Number of refined bool arrays
        nrefn = <np.uint64_t>(ewah_refn[0].numberOfOnes())
        ss.write(<const char *> &nrefn, sizeof(nrefn))
        # Loop over refined bool arrays
        it_map = ewah_coll[0].begin()
        while it_map != ewah_coll[0].end():
            mi1 = dereference(it_map).first
            mi1_ewah = dereference(it_map).second
            ss.write(<const char *> &mi1, sizeof(mi1))
            mi1_ewah.write(ss,1)
            preincrement(it_map)
        # Return type cast python bytes string
        return <bytes>ss.str()

    def dumps(self):
        return self._dumps()

    cdef void _loads(self, bytes s):
        # TODO: write word size
        cdef sstream ss
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef map[np.uint64_t, ewah_bool_array] *ewah_coll = <map[np.uint64_t, ewah_bool_array] *> self.ewah_coll
        cdef map[np.uint64_t, ewah_bool_array].iterator it_map
        cdef np.uint64_t nrefn, mi1
        cdef ewah_bool_array mi1_ewah
        cdef int i
        # Write string to string stream
        ss.write(s, len(s))
        # Read keys and refinment arrays
        ewah_keys[0].read(ss,1)
        ewah_refn[0].read(ss,1)
        # Read and check number of refined cells
        ss.read(<char *> (&nrefn), sizeof(nrefn))
        if nrefn != ewah_refn[0].numberOfOnes():
            raise Exception("Error in read. File indicates {} refinements, but bool array has {}.".format(nrefn,ewah_refn[0].numberOfOnes()))
        # Loop over refined cells
        for i in range(nrefn):
            ss.read(<char *> (&mi1), sizeof(mi1))
            ewah_coll[0][mi1].read(ss,1)
            # or...
            #mi1_ewah.read(ss,1)
            #ewah_coll[0][mi1].swap(mi1_ewah)

    def loads(self, s):
        return self._loads(s)

    def __dealloc__(self):
        cdef ewah_bool_array *ewah_keys = <ewah_bool_array *> self.ewah_keys
        cdef ewah_bool_array *ewah_refn = <ewah_bool_array *> self.ewah_refn
        cdef ewah_bool_array *ewah_coar = <ewah_bool_array *> self.ewah_coar
        cdef ewah_map *ewah_coll = <ewah_map *> self.ewah_coll
        del ewah_keys
        del ewah_refn
        del ewah_coar
        del ewah_coll

cdef class SparseUnorderedBitmask:
    def __cinit__(self):
        cdef vector[np.uint64_t] *entries = new vector[np.uint64_t]()
        self.entries = <void *> entries

    cdef void _set(self, np.uint64_t ind):
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        entries[0].push_back(ind)

    cdef void _fill(self, np.uint8_t[:] mask):
        cdef np.uint64_t i, ind
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        for i in range(entries[0].size()):
            ind = entries[0][i]
            mask[ind] = 1

    cdef void _reset(self):
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        entries[0].erase(entries[0].begin(), entries[0].end())

    cdef to_array(self):
        cdef np.ndarray[np.uint64_t, ndim=1] rv
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        rv = np.empty(entries[0].size(), dtype='uint64')
        for i in range(entries[0].size()):
            rv[i] = entries[0][i]
        return np.unique(rv).astype(np.uint64)

    cdef void _remove_duplicates(self):
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        cdef vector[np.uint64_t].iterator last
        sort(entries[0].begin(), entries[0].end())
        last = unique(entries[0].begin(), entries[0].end())
        entries[0].erase(last, entries[0].end())

    def __dealloc__(self):
        cdef vector[np.uint64_t] *entries = <vector[np.uint64_t]*> self.entries
        del entries

cdef class SparseUnorderedRefinedBitmask:
    def __cinit__(self):
        cdef vector[np.uint64_t] *entries1 = new vector[np.uint64_t]()
        cdef vector[np.uint64_t] *entries2 = new vector[np.uint64_t]()
        self.entries1 = <void *> entries1
        self.entries2 = <void *> entries2

    cdef void _set(self, np.uint64_t ind1, np.uint64_t ind2):
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        entries1[0].push_back(ind1)
        entries2[0].push_back(ind2)

    cdef void _fill(self, np.uint8_t[:] mask1, np.uint8_t[:] mask2):
        cdef np.uint64_t i, ind
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        for i in range(entries1[0].size()):
            ind = entries1[0][i]
            mask1[ind] = 1
            ind = entries2[0][i]
            mask2[ind] = 1

    cdef void _reset(self):
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        entries1[0].erase(entries1[0].begin(), entries1[0].end())
        entries2[0].erase(entries2[0].begin(), entries2[0].end())

    cdef to_array(self):
        cdef np.ndarray[np.uint64_t, ndim=2] rv
        # cdef np.ndarray[np.uint64_t, ndim=1] iv
        # cdef np.ndarray[np.uint64_t, ndim=1] _
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        rv = np.empty((entries1[0].size(),2),dtype='uint64')
        for i in range(entries1[0].size()):
            rv[i,0] = entries1[0][i]
            rv[i,1] = entries2[0][i]
        _, iv = np.unique(np.ascontiguousarray(rv).view(np.dtype((np.void, rv.dtype.itemsize * rv.shape[1]))),
                          return_index=True)
        return rv[iv]

    cdef void _remove_duplicates(self):
        cdef np.ndarray[np.uint64_t, ndim=2] rv
        cdef np.ndarray[long, ndim=1] iv
        cdef np.uint64_t m
        cdef vector[np.uint64_t].iterator last1
        cdef vector[np.uint64_t].iterator last2
        # cdef np.ndarray[np.uint64_t, ndim=1] _
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        rv = np.empty((entries1[0].size(),2),dtype='uint64')
        for i in range(entries1[0].size()):
            rv[i,0] = entries1[0][i]
            rv[i,1] = entries2[0][i]
        _, iv = np.unique(np.ascontiguousarray(rv).view(np.dtype((np.void, rv.dtype.itemsize * rv.shape[1]))),
                          return_index=True)
        last1 = entries1[0].begin() + iv.shape[0]
        last2 = entries2[0].begin() + iv.shape[0]
        for m in range(iv.shape[0]):
            entries1[0][m] = rv[iv[m],0]
            entries2[0][m] = rv[iv[m],1]
        entries1[0].erase(last1, entries1[0].end())
        entries2[0].erase(last2, entries2[0].end())

    def __dealloc__(self):
        cdef vector[np.uint64_t] *entries1 = <vector[np.uint64_t]*> self.entries1
        cdef vector[np.uint64_t] *entries2 = <vector[np.uint64_t]*> self.entries2
        del entries1
        del entries2

