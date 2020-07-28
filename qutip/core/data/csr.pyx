#cython: language_level=3
#cython: boundscheck=False, wraparound=False, initializedcheck=False

from libc.string cimport memset, memcpy
from libcpp.algorithm cimport sort
from libcpp.vector cimport vector

cimport cython

import warnings

import numpy as np
cimport numpy as cnp
from scipy.sparse import csr_matrix as scipy_csr_matrix
from scipy.sparse.data import _data_matrix as scipy_data_matrix

from . cimport base

cnp.import_array()

cdef extern from *:
    void PyArray_ENABLEFLAGS(cnp.ndarray arr, int flags)
    void *PyDataMem_NEW(size_t size)
    void PyDataMem_FREE(void *ptr)


cdef object _csr_matrix(data, indices, indptr, shape):
    """
    Factory method of scipy csr_matrix: we skip all the index type-checking
    because this takes tens of microseconds, and we already know we're in
    a sensible format.
    """
    cdef object out = scipy_csr_matrix.__new__(scipy_csr_matrix)
    # `_data_matrix` is the first object in the inheritance chain which
    # doesn't have a really slow __init__.
    scipy_data_matrix.__init__(out)
    out.data = data
    out.indices = indices
    out.indptr = indptr
    out._shape = shape
    return out


cdef class CSR(base.Data):
    """
    Data type for quantum objects storing its data in compressed sparse row
    (CSR) format.  This is similar to the `scipy` type
    `scipy.sparse.csr_matrix`, but significantly faster on many operations.
    You can retrieve a `scipy.sparse.csr_matrix` which views onto the same data
    using the `as_scipy()` method.
    """
    def __cinit__(self, *args, **kwargs):
        # By default, we want CSR to deallocate its memory (we depend on Cython
        # to ensure we don't deallocate a NULL pointer), and we only flip this
        # when we create a scipy backing.  Since creating the scipy backing
        # depends on knowing the shape, which happens _after_ data
        # initialisation and may throw an exception, it is better to have a
        # single flag that is set as soon as the pointers are assigned.
        self._deallocate = True

    def __init__(self, arg=None, shape=None, bint copy=False):
        # This is the Python __init__ method, so we do not care that it is not
        # super-fast C access.  Typically Cython code will not call this, but
        # will use a factory method in this module or at worst, call
        # CSR.__new__ and manually set everything.  We must be very careful in
        # this function that the deallocation is set up correctly if any
        # exceptions occur.
        cdef size_t ptr
        cdef base.idxint col
        cdef object data, col_index, row_index
        if isinstance(arg, scipy_csr_matrix):
            if shape is not None and shape != arg.shape:
                raise ValueError("".join([
                    "shapes do not match: ", str(shape), " and ", str(arg.shape),
                ]))
            shape = arg.shape
            arg = (arg.data, arg.indices, arg.indptr)
        if not isinstance(arg, tuple):
            raise TypeError("arg must be a scipy csr_matrix or tuple")
        if len(arg) != 3:
            raise ValueError("arg must be a (data, col_index, row_index) tuple")
        data = np.array(arg[0], dtype=np.complex128, copy=copy)
        col_index = np.array(arg[1], dtype=base.idxint_dtype, copy=copy)
        row_index = np.array(arg[2], dtype=base.idxint_dtype, copy=copy)
        # This flag must be set at the same time as data, col_index and
        # row_index are assigned.  These assignments cannot raise an exception
        # in user code due to the above three lines, but further code may.
        self._deallocate = False
        self.data = data
        self.col_index = col_index
        self.row_index = row_index
        if shape is None:
            warnings.warn("instantiating CSR matrix of unknown shape")
            # row_index contains an extra element which is nnz.  We assume the
            # smallest matrix which can hold all these values by iterating
            # through the columns.  This is slow and probably inaccurate, since
            # there could be columns containing zero (hence the warning).
            self.shape[0] = self.row_index.shape[0] - 1
            col = 1
            for ptr in range(self.col_index.shape[0]):
                col = self.col_index[ptr] if self.col_index[ptr] > col else col
            self.shape[1] = col
        else:
            if not isinstance(shape, tuple):
                raise TypeError("shape must be a 2-tuple of positive ints")
            if not (len(shape) == 2
                    and isinstance(shape[0], int)
                    and isinstance(shape[1], int)
                    and shape[0] > 0
                    and shape[1] > 0):
                raise ValueError("shape must be a 2-tuple of positive ints")
            self.shape = shape
        # Store a reference to the backing scipy matrix so it doesn't get
        # deallocated before us.
        self._scipy = _csr_matrix(data, col_index, row_index, self.shape)

    cpdef CSR copy(self):
        """
        Return a complete (deep) copy of this object.

        If the type currently has a scipy backing, such as that produced by
        `as_scipy`, this will not be copied.  The backing is a view onto our
        data, and a straight copy of this view would be incorrect.  We do not
        create a new view at copy time, since the user may only access this
        through a creation method, and creating it ahead of time would incur an
        unnecessary speed penalty for users who do not need it (including
        low-level C code).
        """
        cdef base.idxint nnz_ = nnz(self)
        cdef CSR out = empty(self.shape[0], self.shape[1], nnz_)
        memcpy(&out.data[0], &self.data[0], nnz_*sizeof(out.data[0]))
        memcpy(&out.col_index[0], &self.col_index[0], nnz_*sizeof(out.col_index[0]))
        memcpy(&out.row_index[0], &self.row_index[0],
               (self.shape[0] + 1)*sizeof(out.row_index[0]))
        return out

    cpdef object to_array(self):
        """
        Get a copy of this data as a full 2D, C-contiguous NumPy array.  This
        is not a view onto the data, and changes to new array will not affect
        the original data structure.
        """
        cdef cnp.npy_intp *dims = [self.shape[0], self.shape[1]]
        cdef object out = cnp.PyArray_ZEROS(2, dims, cnp.NPY_COMPLEX128, 0)
        cdef double complex [:, ::1] buffer = out
        cdef size_t row, ptr
        for row in range(self.shape[0]):
            for ptr in range(self.row_index[row], self.row_index[row + 1]):
                buffer[row, self.col_index[ptr]] = self.data[ptr]
        return out

    cpdef object as_scipy(self):
        """
        Get a view onto this object as a `scipy.sparse.csr_matrix`.  The
        underlying data structures are exposed, such that modifications to the
        `data`, `indices` and `indptr` buffers in the resulting object will
        modify this object too.

        The arrays may be uninitialised.
        """
        # We store a reference to the scipy matrix not only for caching this
        # relatively expensive method, but also because we transferred
        # ownership of our data to the numpy arrays, and we can't allow them to
        # be collected while we're alive.
        if self._scipy is not None:
            return self._scipy
        data = cnp.PyArray_SimpleNewFromData(1, [self.data.size],
                                             cnp.NPY_COMPLEX128,
                                             &self.data[0])
        indices = cnp.PyArray_SimpleNewFromData(1, [self.col_index.size],
                                                base.idxint_DTYPE,
                                                &self.col_index[0])
        indptr = cnp.PyArray_SimpleNewFromData(1, [self.row_index.size],
                                               base.idxint_DTYPE,
                                               &self.row_index[0])
        PyArray_ENABLEFLAGS(data, cnp.NPY_ARRAY_OWNDATA)
        PyArray_ENABLEFLAGS(indices, cnp.NPY_ARRAY_OWNDATA)
        PyArray_ENABLEFLAGS(indptr, cnp.NPY_ARRAY_OWNDATA)
        self._deallocate = False
        self._scipy = _csr_matrix(data, indices, indptr, self.shape)
        return self._scipy

    def __repr__(self):
        return "".join([
            "CSR(shape=", str(self.shape), ", nnz=", str(nnz(self)), ")",
        ])

    def __str__(self):
        return self.__repr__()

    @cython.initializedcheck(True)
    def __dealloc__(self):
        # If we have a reference to a scipy type, then we've passed ownership
        # of the data to numpy, so we let it handle refcounting and we don't
        # need to deallocate anything ourselves.
        if not self._deallocate:
            return
        # The only way a Cython memoryview can hold a NULL pointer is if the
        # memoryview is uninitialised.  Since we have initializedcheck on,
        # Cython will insert a throw if it is not initialized, and therefore
        # accessing &self.data[0] is safe and non-NULL if no error occurs.
        try:
            PyDataMem_FREE(&self.data[0])
        except AttributeError:
            pass
        try:
            PyDataMem_FREE(&self.col_index[0])
        except AttributeError:
            pass
        try:
            PyDataMem_FREE(&self.row_index[0])
        except AttributeError:
            pass


cpdef CSR copy_structure(CSR matrix):
    """
    Return a copy of the input matrix with identical `col_index` and
    `row_index` matrices, and an allocated, but empty, `data`.  The returned
    pointers are all separately allocated, but contain the same information.

    This is intended for unary functions on CSR types that maintain the exact
    structure, but modify each non-zero data element without change their
    location.
    """
    cdef base.idxint nnz_ = nnz(matrix)
    cdef CSR out = empty(matrix.shape[0], matrix.shape[1], nnz_)
    memcpy(&out.col_index[0], &matrix.col_index[0], nnz_*sizeof(out.col_index[0]))
    memcpy(&out.row_index[0], &matrix.row_index[0],
           (matrix.shape[0] + 1)*sizeof(out.row_index[0]))
    return out


cpdef inline base.idxint nnz(CSR matrix) nogil:
    """Get the number of non-zero elements of a CSR matrix."""
    return matrix.row_index[matrix.shape[0]]


# Internal structure for sorting pairs of elements.
cdef struct _data_col:
    double complex data
    base.idxint col

cdef int _sort_indices_compare(_data_col x, _data_col y) nogil:
    return x.col < y.col

cpdef void sort_indices(CSR matrix) nogil:
    """Sort the column indices and data of the matrix inplace."""
    cdef base.idxint row, ptr, ptr_start, ptr_end, length
    cdef vector[_data_col] pairs
    for row in range(matrix.shape[0]):
        ptr_start = matrix.row_index[row]
        ptr_end = matrix.row_index[row + 1]
        length = ptr_end - ptr_start
        pairs.resize(length)
        for ptr in range(length):
            pairs[ptr].data = matrix.data[ptr_start + ptr]
            pairs[ptr].col = matrix.col_index[ptr_start + ptr]
        sort(pairs.begin(), pairs.end(), &_sort_indices_compare)
        for ptr in range(length):
            matrix.data[ptr_start + ptr] = pairs[ptr].data
            matrix.col_index[ptr_start + ptr] = pairs[ptr].col


cpdef CSR empty(base.idxint rows, base.idxint cols, base.idxint size):
    """
    Allocate an empty CSR matrix of the given shape, with space for `size`
    elements in the `data` and `col_index` arrays.

    This does not initialise any of the memory returned, but sets the last
    element of `row_index` to 0 to indicate that there are 0 non-zero elements.
    """
    if size < 0:
        raise ValueError("size must be a positive integer.")
    # Python doesn't like allocating nothing.
    if size == 0:
        size += 1
    cdef CSR out = CSR.__new__(CSR)
    cdef base.idxint row_size = rows + 1
    out.shape = (rows, cols)
    out.data =\
        <double complex [:size]> PyDataMem_NEW(size * sizeof(double complex))
    out.col_index =\
        <base.idxint [:size]> PyDataMem_NEW(size * sizeof(base.idxint))
    out.row_index =\
        <base.idxint [:row_size]> PyDataMem_NEW(row_size * sizeof(base.idxint))
    # Set the number of non-zero elements to 0.
    out.row_index[rows] = 0
    return out


cpdef CSR zeros(base.idxint rows, base.idxint cols):
    """
    Allocate the zero matrix with a given shape.  There will not be any room in
    the `data` and `col_index` buffers to add new elements.
    """
    # We always allocate matrices with at least one element to ensure that we
    # actually _are_ asking for memory (Python doesn't like allocating nothing)
    cdef CSR out = empty(rows, cols, 1)
    out.data[0] = out.col_index[0] = 0
    memset(&out.row_index[0], 0, (rows + 1) * sizeof(base.idxint))
    return out


cpdef CSR identity(base.idxint dimension, double complex scale=1):
    """
    Return a square matrix of the specified dimension, with a constant along
    the diagonal.  By default this will be the identity matrix, but if `scale`
    is passed, then the result will be `scale` times the identity.
    """
    cdef CSR out = empty(dimension, dimension, dimension)
    cdef base.idxint i
    for i in range(dimension):
        out.data[i] = scale
        out.col_index[i] = i
        out.row_index[i] = i
    out.row_index[dimension] = dimension
    return out