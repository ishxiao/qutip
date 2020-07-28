#cython: language_level=3

import numpy as np
cimport numpy as cnp

from . cimport base

cdef class CSR(base.Data):
    cdef double complex [::1] data
    cdef base.idxint [::1] col_index
    cdef base.idxint [::1] row_index
    cdef object _scipy
    cdef bint _deallocate
    cpdef CSR copy(CSR self)
    cpdef object as_scipy(CSR self)

cpdef CSR copy_structure(CSR matrix)
cpdef void sort_indices(CSR matrix) nogil
cpdef base.idxint nnz(CSR matrix) nogil
cpdef CSR empty(base.idxint rows, base.idxint cols, base.idxint size)
cpdef CSR zeros(base.idxint rows, base.idxint cols)
cpdef CSR identity(base.idxint dimension, double complex scale=*)