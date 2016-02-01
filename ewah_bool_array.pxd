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

cimport numpy as np
cimport cython
from libcpp.vector cimport vector
from libcpp.map cimport map

cdef extern from "ewah.h":
    cdef cppclass EWAHBoolArray[uword]:
        # We are going to skip the varargs here; it is too tricky to assemble.
        bint get(const size_t pos)
        bint set(size_t i)
        void makeSameSize(EWAHBoolArray &a)
        vector[size_t] toArray()
        void logicaland(EWAHBoolArray &a, EWAHBoolArray &container)
        void logicalor(EWAHBoolArray &a, EWAHBoolArray &container)
        void logicalxor(EWAHBoolArray &a, EWAHBoolArray &container)
        bint intersects(EWAHBoolArray &a)
        void reset()
        size_t sizeInBits()
        size_t sizeInBytes()
        bint operator==(EWAHBoolArray &x)
        bint operator!=(EWAHBoolArray &x)
        void append(EWAHBoolArray &x)
        # Recommended container is "vector[size_t]"
        void appendRowIDs[container](container &out, const size_t offset)
        void appendSetBits[container](container &out, const size_t offset)
        size_t numberOfOnes()
        void logicalnot(EWAHBoolArray &x)
        void inplace_logicalnot()
        void swap(EWAHBoolArray &x)

ctypedef EWAHBoolArray[np.uint32_t] ewah_bool_array
ctypedef vector[size_t] bitset_array
ctypedef map[np.uint64_t, ewah_bool_array] ewah_map
