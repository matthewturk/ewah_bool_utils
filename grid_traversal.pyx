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
#cimport healpix_interface
cdef extern from "limits.h":
    cdef int SHRT_MAX
from libc.stdlib cimport malloc, calloc, free, abs
from libc.math cimport exp, floor, log2, \
    lrint, fabs, atan, atan2, asin, cos, sin, sqrt, acos, M_PI
from yt.utilities.lib.fp_utils cimport imax, fmax, imin, fmin, iclip, fclip, i64clip
from field_interpolation_tables cimport \
    FieldInterpolationTable, FIT_initialize_table, FIT_eval_transfer,\
    FIT_eval_transfer_with_light
from fixed_interpolator cimport *

from cython.parallel import prange, parallel, threadid
from vec3_ops cimport dot, subtract, L2_norm, fma

from cpython.exc cimport PyErr_CheckSignals

DEF Nch = 4

cdef class PartitionedGrid:

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def __cinit__(self,
                  int parent_grid_id, data,
                  mask,
                  np.ndarray[np.float64_t, ndim=1] left_edge,
                  np.ndarray[np.float64_t, ndim=1] right_edge,
                  np.ndarray[np.int64_t, ndim=1] dims,
		  star_kdtree_container star_tree = None):
        # The data is likely brought in via a slice, so we copy it
        cdef np.ndarray[np.float64_t, ndim=3] tdata
        cdef np.ndarray[np.uint8_t, ndim=3] mask_data
        self.container = NULL
        self.parent_grid_id = parent_grid_id
        self.LeftEdge = left_edge
        self.RightEdge = right_edge
        self.container = <VolumeContainer *> \
            malloc(sizeof(VolumeContainer))
        cdef VolumeContainer *c = self.container # convenience
        cdef int n_fields = len(data)
        c.n_fields = n_fields
        for i in range(3):
            c.left_edge[i] = left_edge[i]
            c.right_edge[i] = right_edge[i]
            c.dims[i] = dims[i]
            c.dds[i] = (c.right_edge[i] - c.left_edge[i])/dims[i]
            c.idds[i] = 1.0/c.dds[i]
        self.my_data = data
        self.source_mask = mask
        mask_data = mask
        c.data = <np.float64_t **> malloc(sizeof(np.float64_t*) * n_fields)
        for i in range(n_fields):
            tdata = data[i]
            c.data[i] = <np.float64_t *> tdata.data
        c.mask = <np.uint8_t *> mask_data.data
        if star_tree is None:
            self.star_list = NULL
        else:
            self.set_star_tree(star_tree)

    def set_star_tree(self, star_kdtree_container star_tree):
        self.star_list = star_tree.tree
        self.star_sigma_num = 2.0*star_tree.sigma**2.0
        self.star_er = 2.326 * star_tree.sigma
        self.star_coeff = star_tree.coeff

    def __dealloc__(self):
        # The data fields are not owned by the container, they are owned by us!
        # So we don't need to deallocate them.
        if self.container == NULL: return
        if self.container.data != NULL: free(self.container.data)
        free(self.container)

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def integrate_streamline(self, pos, np.float64_t h, mag):
        cdef np.float64_t cmag[1]
        cdef np.float64_t k1[3]
        cdef np.float64_t k2[3]
        cdef np.float64_t k3[3]
        cdef np.float64_t k4[3]
        cdef np.float64_t newpos[3]
        cdef np.float64_t oldpos[3]
        for i in range(3):
            newpos[i] = oldpos[i] = pos[i]
        self.get_vector_field(newpos, k1, cmag)
        for i in range(3):
            newpos[i] = oldpos[i] + 0.5*k1[i]*h

        if not (self.LeftEdge[0] < newpos[0] and newpos[0] < self.RightEdge[0] and \
                self.LeftEdge[1] < newpos[1] and newpos[1] < self.RightEdge[1] and \
                self.LeftEdge[2] < newpos[2] and newpos[2] < self.RightEdge[2]):
            if mag is not None:
                mag[0] = cmag[0]
            for i in range(3):
                pos[i] = newpos[i]
            return

        self.get_vector_field(newpos, k2, cmag)
        for i in range(3):
            newpos[i] = oldpos[i] + 0.5*k2[i]*h

        if not (self.LeftEdge[0] <= newpos[0] and newpos[0] <= self.RightEdge[0] and \
                self.LeftEdge[1] <= newpos[1] and newpos[1] <= self.RightEdge[1] and \
                self.LeftEdge[2] <= newpos[2] and newpos[2] <= self.RightEdge[2]):
            if mag is not None:
                mag[0] = cmag[0]
            for i in range(3):
                pos[i] = newpos[i]
            return

        self.get_vector_field(newpos, k3, cmag)
        for i in range(3):
            newpos[i] = oldpos[i] + k3[i]*h

        if not (self.LeftEdge[0] <= newpos[0] and newpos[0] <= self.RightEdge[0] and \
                self.LeftEdge[1] <= newpos[1] and newpos[1] <= self.RightEdge[1] and \
                self.LeftEdge[2] <= newpos[2] and newpos[2] <= self.RightEdge[2]):
            if mag is not None:
                mag[0] = cmag[0]
            for i in range(3):
                pos[i] = newpos[i]
            return

        self.get_vector_field(newpos, k4, cmag)

        for i in range(3):
            pos[i] = oldpos[i] + h*(k1[i]/6.0 + k2[i]/3.0 + k3[i]/3.0 + k4[i]/6.0)

        if mag is not None:
            for i in range(3):
                newpos[i] = pos[i]
            self.get_vector_field(newpos, k4, cmag)
            mag[0] = cmag[0]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    cdef void get_vector_field(self, np.float64_t pos[3],
                               np.float64_t *vel, np.float64_t *vel_mag):
        cdef np.float64_t dp[3]
        cdef int ci[3]
        cdef VolumeContainer *c = self.container # convenience

        for i in range(3):
            ci[i] = (int)((pos[i]-self.LeftEdge[i])/c.dds[i])
            dp[i] = (pos[i] - ci[i]*c.dds[i] - self.LeftEdge[i])/c.dds[i]

        cdef int offset = ci[0] * (c.dims[1] + 1) * (c.dims[2] + 1) \
                          + ci[1] * (c.dims[2] + 1) + ci[2]

        vel_mag[0] = 0.0
        for i in range(3):
            vel[i] = offset_interpolate(c.dims, dp, c.data[i] + offset)
            vel_mag[0] += vel[i]*vel[i]
        vel_mag[0] = np.sqrt(vel_mag[0])
        if vel_mag[0] != 0.0:
            for i in range(3):
                vel[i] /= vel_mag[0]

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void calculate_extent_plane_parallel(ImageContainer *image,
            VolumeContainer *vc, np.int64_t rv[4]) nogil:
    # We do this for all eight corners
    cdef np.float64_t temp
    cdef np.float64_t *edges[2]
    cdef np.float64_t cx, cy
    cdef np.float64_t extrema[4]
    cdef int i, j, k
    edges[0] = vc.left_edge
    edges[1] = vc.right_edge
    extrema[0] = extrema[2] = 1e300; extrema[1] = extrema[3] = -1e300
    for i in range(2):
        for j in range(2):
            for k in range(2):
                # This should rotate it into the vector plane
                temp  = edges[i][0] * image.x_vec[0]
                temp += edges[j][1] * image.x_vec[1]
                temp += edges[k][2] * image.x_vec[2]
                if temp < extrema[0]: extrema[0] = temp
                if temp > extrema[1]: extrema[1] = temp
                temp  = edges[i][0] * image.y_vec[0]
                temp += edges[j][1] * image.y_vec[1]
                temp += edges[k][2] * image.y_vec[2]
                if temp < extrema[2]: extrema[2] = temp
                if temp > extrema[3]: extrema[3] = temp
    cx = cy = 0.0
    for i in range(3):
        cx += image.center[i] * image.x_vec[i]
        cy += image.center[i] * image.y_vec[i]
    rv[0] = lrint((extrema[0] - cx - image.bounds[0])/image.pdx)
    rv[1] = rv[0] + lrint((extrema[1] - extrema[0])/image.pdx)
    rv[2] = lrint((extrema[2] - cy - image.bounds[2])/image.pdy)
    rv[3] = rv[2] + lrint((extrema[3] - extrema[2])/image.pdy)

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void calculate_extent_perspective(ImageContainer *image,
            VolumeContainer *vc, np.int64_t rv[4]) nogil:

    cdef np.float64_t cam_pos[3]
    cdef np.float64_t cam_width[3]
    cdef np.float64_t north_vector[3]
    cdef np.float64_t east_vector[3]
    cdef np.float64_t normal_vector[3]
    cdef np.float64_t vertex[3]
    cdef np.float64_t pos1[3]
    cdef np.float64_t sight_vector[3]
    cdef np.float64_t sight_center[3]
    cdef np.float64_t corners[3][8]
    cdef float sight_vector_norm, sight_angle_cos, sight_length, dx, dy
    cdef int i, iv, px, py
    cdef int min_px, min_py, max_px, max_py

    min_px = SHRT_MAX
    min_py = SHRT_MAX
    max_px = -SHRT_MAX
    max_py = -SHRT_MAX

    # calculate vertices for 8 corners of vc
    corners[0][0] = vc.left_edge[0]
    corners[0][1] = vc.right_edge[0]
    corners[0][2] = vc.right_edge[0]
    corners[0][3] = vc.left_edge[0]
    corners[0][4] = vc.left_edge[0]
    corners[0][5] = vc.right_edge[0]
    corners[0][6] = vc.right_edge[0]
    corners[0][7] = vc.left_edge[0]

    corners[1][0] = vc.left_edge[1]
    corners[1][1] = vc.left_edge[1]
    corners[1][2] = vc.right_edge[1]
    corners[1][3] = vc.right_edge[1]
    corners[1][4] = vc.left_edge[1]
    corners[1][5] = vc.left_edge[1]
    corners[1][6] = vc.right_edge[1]
    corners[1][7] = vc.right_edge[1]

    corners[2][0] = vc.left_edge[2]
    corners[2][1] = vc.left_edge[2]
    corners[2][2] = vc.left_edge[2]
    corners[2][3] = vc.left_edge[2]
    corners[2][4] = vc.right_edge[2]
    corners[2][5] = vc.right_edge[2]
    corners[2][6] = vc.right_edge[2]
    corners[2][7] = vc.right_edge[2]

    # This code was ported from
    #   yt.visualization.volume_rendering.lens.PerspectiveLens.project_to_plane()
    for i in range(3):
        cam_pos[i] = image.camera_data[0, i]
        cam_width[i] = image.camera_data[1, i]
        east_vector[i] = image.camera_data[2, i]
        north_vector[i] = image.camera_data[3, i]
        normal_vector[i] = image.camera_data[4, i]

    for iv in range(8):
        vertex[0] = corners[0][iv]
        vertex[1] = corners[1][iv]
        vertex[2] = corners[2][iv]

        cam_width[1] = cam_width[0] * image.nv[1] / image.nv[0]

        subtract(vertex, cam_pos, sight_vector)
        fma(cam_width[2], normal_vector, cam_pos, sight_center)

        sight_vector_norm = L2_norm(sight_vector)
       
        if sight_vector_norm != 0:
            for i in range(3):
                sight_vector[i] /= sight_vector_norm

        sight_angle_cos = dot(sight_vector, normal_vector)
        sight_angle_cos = fclip(sight_angle_cos, -1.0, 1.0)

        if acos(sight_angle_cos) < 0.5 * M_PI and sight_angle_cos != 0.0:
            sight_length = cam_width[2] / sight_angle_cos
        else:
            sight_length = sqrt(cam_width[0]**2 + cam_width[1]**2)
            sight_length = sight_length / sqrt(1.0 - sight_angle_cos**2)

        fma(sight_length, sight_vector, cam_pos, pos1)
        subtract(pos1, sight_center, pos1)
        dx = dot(pos1, east_vector)
        dy = dot(pos1, north_vector)

        px = int(image.nv[0] * 0.5 + image.nv[0] / cam_width[0] * dx)
        py = int(image.nv[1] * 0.5 + image.nv[1] / cam_width[1] * dy)
        min_px = min(min_px, px)
        max_px = max(max_px, px)
        min_py = min(min_py, py)
        max_py = max(max_py, py)

    rv[0] = max(min_px, 0)
    rv[1] = min(max_px, image.nv[0])
    rv[2] = max(min_py, 0)
    rv[3] = min(max_py, image.nv[1])


# We do this for a bunch of lenses.  Fallback is to grab them from the vector
# info supplied.

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void calculate_extent_null(ImageContainer *image,
            VolumeContainer *vc, np.int64_t rv[4]) nogil:
    rv[0] = 0
    rv[1] = image.nv[0]
    rv[2] = 0
    rv[3] = image.nv[1]

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void generate_vector_info_plane_parallel(ImageContainer *im,
            np.int64_t vi, np.int64_t vj,
            np.float64_t width[2],
            # Now outbound
            np.float64_t v_dir[3], np.float64_t v_pos[3]) nogil:
    cdef int i
    cdef np.float64_t px, py
    px = width[0] * (<np.float64_t>vi)/(<np.float64_t>im.nv[0]-1) - width[0]/2.0
    py = width[1] * (<np.float64_t>vj)/(<np.float64_t>im.nv[1]-1) - width[1]/2.0
    # atleast_3d will add to beginning and end
    v_pos[0] = im.vp_pos[0,0,0]*px + im.vp_pos[0,3,0]*py + im.vp_pos[0,9,0]
    v_pos[1] = im.vp_pos[0,1,0]*px + im.vp_pos[0,4,0]*py + im.vp_pos[0,10,0]
    v_pos[2] = im.vp_pos[0,2,0]*px + im.vp_pos[0,5,0]*py + im.vp_pos[0,11,0]
    for i in range(3): v_dir[i] = im.vp_dir[0,i,0]

@cython.boundscheck(False)
@cython.wraparound(False)
cdef void generate_vector_info_null(ImageContainer *im,
            np.int64_t vi, np.int64_t vj,
            np.float64_t width[2],
            # Now outbound
            np.float64_t v_dir[3], np.float64_t v_pos[3]) nogil:
    cdef int i
    for i in range(3):
        # Here's a funny thing: we use vi here because our *image* will be
        # flattened.  That means that im.nv will be a better one-d offset,
        # since vp_pos has funny strides.
        v_pos[i] = im.vp_pos[vi, vj, i]
        v_dir[i] = im.vp_dir[vi, vj, i]

cdef struct ImageAccumulator:
    np.float64_t rgba[Nch]
    void *supp_data

cdef class ImageSampler:
    def __init__(self,
                  np.float64_t[:,:,:] vp_pos,
                  np.float64_t[:,:,:] vp_dir,
                  np.ndarray[np.float64_t, ndim=1] center,
                  bounds,
                  np.ndarray[np.float64_t, ndim=3] image,
                  np.ndarray[np.float64_t, ndim=1] x_vec,
                  np.ndarray[np.float64_t, ndim=1] y_vec,
                  np.ndarray[np.float64_t, ndim=1] width,
                  *args, **kwargs):
        self.image = <ImageContainer *> calloc(sizeof(ImageContainer), 1)
        cdef np.float64_t[:,:] zbuffer
        cdef np.int64_t[:,:] image_used
        cdef np.int64_t[:,:] mesh_lines
        cdef np.float64_t[:,:] camera_data
        cdef int i

        camera_data = kwargs.pop("camera_data", None)
        if camera_data is not None:
            self.image.camera_data = camera_data

        zbuffer = kwargs.pop("zbuffer", None)
        if zbuffer is None:
            zbuffer = np.ones((image.shape[0], image.shape[1]), "float64")

        image_used = np.zeros((image.shape[0], image.shape[1]), "int64")
        mesh_lines = np.zeros((image.shape[0], image.shape[1]), "int64")

        self.lens_type = kwargs.pop("lens_type", None)
        if self.lens_type == "plane-parallel":
            self.extent_function = calculate_extent_plane_parallel
            self.vector_function = generate_vector_info_plane_parallel
        else:
            if not (vp_pos.shape[0] == vp_dir.shape[0] == image.shape[0]) or \
               not (vp_pos.shape[1] == vp_dir.shape[1] == image.shape[1]):
                msg = "Bad lens shape / direction for %s\n" % (self.lens_type)
                msg += "Shapes: (%s - %s - %s) and (%s - %s - %s)" % (
                    vp_pos.shape[0], vp_dir.shape[0], image.shape[0],
                    vp_pos.shape[1], vp_dir.shape[1], image.shape[1])
                raise RuntimeError(msg)

            if camera_data is not None and self.lens_type == 'perspective':
                self.extent_function = calculate_extent_perspective
            else:
                self.extent_function = calculate_extent_null
            self.vector_function = generate_vector_info_null

        self.sampler = NULL
        # These assignments are so we can track the objects and prevent their
        # de-allocation from reference counts.  Note that we do this to the
        # "atleast_3d" versions.  Also, note that we re-assign the input
        # arguments.
        self.image.vp_pos = vp_pos
        self.image.vp_dir = vp_dir
        self.image.image = self.aimage = image
        self.acenter = center
        self.image.center = <np.float64_t *> center.data
        self.ax_vec = x_vec
        self.image.x_vec = <np.float64_t *> x_vec.data
        self.ay_vec = y_vec
        self.image.y_vec = <np.float64_t *> y_vec.data
        self.image.zbuffer = self.azbuffer = zbuffer
        self.image.image_used = self.aimage_used = image_used
        self.image.mesh_lines = self.amesh_lines = mesh_lines
        self.image.nv[0] = image.shape[0]
        self.image.nv[1] = image.shape[1]
        for i in range(4): self.image.bounds[i] = bounds[i]
        self.image.pdx = (bounds[1] - bounds[0])/self.image.nv[0]
        self.image.pdy = (bounds[3] - bounds[2])/self.image.nv[1]
        for i in range(3):
            self.width[i] = width[i]

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def __call__(self, PartitionedGrid pg, int num_threads = 0):
        # This routine will iterate over all of the vectors and cast each in
        # turn.  Might benefit from a more sophisticated intersection check,
        # like http://courses.csusm.edu/cs697exz/ray_box.htm
        cdef int vi, vj, hit, i, j
        cdef np.int64_t iter[4]
        cdef VolumeContainer *vc = pg.container
        cdef ImageContainer *im = self.image
        self.setup(pg)
        if self.sampler == NULL: raise RuntimeError
        cdef np.float64_t *v_pos
        cdef np.float64_t *v_dir
        cdef np.float64_t max_t
        hit = 0
        cdef np.int64_t nx, ny, size
        self.extent_function(self.image, vc, iter)
        iter[0] = i64clip(iter[0]-1, 0, im.nv[0])
        iter[1] = i64clip(iter[1]+1, 0, im.nv[0])
        iter[2] = i64clip(iter[2]-1, 0, im.nv[1])
        iter[3] = i64clip(iter[3]+1, 0, im.nv[1])
        nx = (iter[1] - iter[0])
        ny = (iter[3] - iter[2])
        size = nx * ny
        cdef ImageAccumulator *idata
        cdef np.float64_t width[3]
        cdef int chunksize = 100
        for i in range(3):
            width[i] = self.width[i]
        with nogil, parallel(num_threads = num_threads):
            idata = <ImageAccumulator *> malloc(sizeof(ImageAccumulator))
            idata.supp_data = self.supp_data
            v_pos = <np.float64_t *> malloc(3 * sizeof(np.float64_t))
            v_dir = <np.float64_t *> malloc(3 * sizeof(np.float64_t))
            for j in prange(size, schedule="static", chunksize=chunksize):
                vj = j % ny
                vi = (j - vj) / ny + iter[0]
                vj = vj + iter[2]
                # Dynamically calculate the position
                self.vector_function(im, vi, vj, width, v_dir, v_pos)
                for i in range(Nch):
                    idata.rgba[i] = im.image[vi, vj, i]
                max_t = fclip(im.zbuffer[vi, vj], 0.0, 1.0)
                walk_volume(vc, v_pos, v_dir, self.sampler,
                            (<void *> idata), NULL, max_t)
                if (j % (10*chunksize)) == 0:
                    with gil:
                        PyErr_CheckSignals()
                for i in range(Nch):
                    im.image[vi, vj, i] = idata.rgba[i]
            free(idata)
            free(v_pos)
            free(v_dir)
        return hit

    cdef void setup(self, PartitionedGrid pg):
        return

    def __dealloc__(self):
        self.image.image = None
        self.image.vp_pos = None
        self.image.vp_dir = None
        self.image.zbuffer = None
        self.image.camera_data = None
        self.image.image_used = None
        free(self.image)


cdef void projection_sampler(
                 VolumeContainer *vc,
                 np.float64_t v_pos[3],
                 np.float64_t v_dir[3],
                 np.float64_t enter_t,
                 np.float64_t exit_t,
                 int index[3],
                 void *data) nogil:
    cdef ImageAccumulator *im = <ImageAccumulator *> data
    cdef int i
    cdef np.float64_t dl = (exit_t - enter_t)
    cdef int di = (index[0]*vc.dims[1]+index[1])*vc.dims[2]+index[2]
    for i in range(imin(4, vc.n_fields)):
        im.rgba[i] += vc.data[i][di] * dl

cdef struct VolumeRenderAccumulator:
    int n_fits
    int n_samples
    FieldInterpolationTable *fits
    int field_table_ids[6]
    np.float64_t star_coeff
    np.float64_t star_er
    np.float64_t star_sigma_num
    kdtree_utils.kdtree *star_list
    np.float64_t *light_dir
    np.float64_t *light_rgba
    int grey_opacity


cdef class ProjectionSampler(ImageSampler):
    cdef void setup(self, PartitionedGrid pg):
        self.sampler = projection_sampler

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void interpolated_projection_sampler(
                 VolumeContainer *vc,
                 np.float64_t v_pos[3],
                 np.float64_t v_dir[3],
                 np.float64_t enter_t,
                 np.float64_t exit_t,
                 int index[3],
                 void *data) nogil:
    cdef ImageAccumulator *im = <ImageAccumulator *> data
    cdef VolumeRenderAccumulator *vri = <VolumeRenderAccumulator *> \
            im.supp_data
    # we assume this has vertex-centered data.
    cdef int offset = index[0] * (vc.dims[1] + 1) * (vc.dims[2] + 1) \
                    + index[1] * (vc.dims[2] + 1) + index[2]
    cdef np.float64_t dp[3]
    cdef np.float64_t ds[3]
    cdef np.float64_t dt = (exit_t - enter_t) / vri.n_samples
    cdef np.float64_t dvs[6]
    for i in range(3):
        dp[i] = (enter_t + 0.5 * dt) * v_dir[i] + v_pos[i]
        dp[i] -= index[i] * vc.dds[i] + vc.left_edge[i]
        dp[i] *= vc.idds[i]
        ds[i] = v_dir[i] * vc.idds[i] * dt
    for i in range(vri.n_samples):
        for j in range(vc.n_fields):
            dvs[j] = offset_interpolate(vc.dims, dp,
                    vc.data[j] + offset)
        for j in range(imin(3, vc.n_fields)):
            im.rgba[j] += dvs[j] * dt
        for j in range(3):
            dp[j] += ds[j]

cdef class InterpolatedProjectionSampler(ImageSampler):
    cdef VolumeRenderAccumulator *vra
    cdef public object tf_obj
    cdef public object my_field_tables
    def __cinit__(self,
                  np.ndarray vp_pos,
                  np.ndarray vp_dir,
                  np.ndarray[np.float64_t, ndim=1] center,
                  bounds,
                  np.ndarray[np.float64_t, ndim=3] image,
                  np.ndarray[np.float64_t, ndim=1] x_vec,
                  np.ndarray[np.float64_t, ndim=1] y_vec,
                  np.ndarray[np.float64_t, ndim=1] width,
                  n_samples = 10, **kwargs):
        ImageSampler.__init__(self, vp_pos, vp_dir, center, bounds, image,
                               x_vec, y_vec, width, **kwargs)
        # Now we handle tf_obj
        self.vra = <VolumeRenderAccumulator *> \
            malloc(sizeof(VolumeRenderAccumulator))
        self.vra.n_samples = n_samples
        self.supp_data = <void *> self.vra

    cdef void setup(self, PartitionedGrid pg):
        self.sampler = interpolated_projection_sampler

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void volume_render_sampler(
                 VolumeContainer *vc,
                 np.float64_t v_pos[3],
                 np.float64_t v_dir[3],
                 np.float64_t enter_t,
                 np.float64_t exit_t,
                 int index[3],
                 void *data) nogil:
    cdef ImageAccumulator *im = <ImageAccumulator *> data
    cdef VolumeRenderAccumulator *vri = <VolumeRenderAccumulator *> \
            im.supp_data
    # we assume this has vertex-centered data.
    cdef int offset = index[0] * (vc.dims[1] + 1) * (vc.dims[2] + 1) \
                    + index[1] * (vc.dims[2] + 1) + index[2]
    cdef int cell_offset = index[0] * (vc.dims[1]) * (vc.dims[2]) \
                    + index[1] * (vc.dims[2]) + index[2]
    if vc.mask[cell_offset] != 1:
        return
    cdef np.float64_t dp[3]
    cdef np.float64_t ds[3]
    cdef np.float64_t dt = (exit_t - enter_t) / vri.n_samples
    cdef np.float64_t dvs[6]
    for i in range(3):
        dp[i] = (enter_t + 0.5 * dt) * v_dir[i] + v_pos[i]
        dp[i] -= index[i] * vc.dds[i] + vc.left_edge[i]
        dp[i] *= vc.idds[i]
        ds[i] = v_dir[i] * vc.idds[i] * dt
    for i in range(vri.n_samples):
        for j in range(vc.n_fields):
            dvs[j] = offset_interpolate(vc.dims, dp,
                    vc.data[j] + offset)
        FIT_eval_transfer(dt, dvs, im.rgba, vri.n_fits,
                vri.fits, vri.field_table_ids, vri.grey_opacity)
        for j in range(3):
            dp[j] += ds[j]


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void volume_render_gradient_sampler(
                 VolumeContainer *vc,
                 np.float64_t v_pos[3],
                 np.float64_t v_dir[3],
                 np.float64_t enter_t,
                 np.float64_t exit_t,
                 int index[3],
                 void *data) nogil:
    cdef ImageAccumulator *im = <ImageAccumulator *> data
    cdef VolumeRenderAccumulator *vri = <VolumeRenderAccumulator *> \
            im.supp_data
    # we assume this has vertex-centered data.
    cdef int offset = index[0] * (vc.dims[1] + 1) * (vc.dims[2] + 1) \
                    + index[1] * (vc.dims[2] + 1) + index[2]
    cdef np.float64_t dp[3]
    cdef np.float64_t ds[3]
    cdef np.float64_t dt = (exit_t - enter_t) / vri.n_samples
    cdef np.float64_t dvs[6]
    cdef np.float64_t *grad
    grad = <np.float64_t *> malloc(3 * sizeof(np.float64_t))
    for i in range(3):
        dp[i] = (enter_t + 0.5 * dt) * v_dir[i] + v_pos[i]
        dp[i] -= index[i] * vc.dds[i] + vc.left_edge[i]
        dp[i] *= vc.idds[i]
        ds[i] = v_dir[i] * vc.idds[i] * dt
    for i in range(vri.n_samples):
        for j in range(vc.n_fields):
            dvs[j] = offset_interpolate(vc.dims, dp,
                    vc.data[j] + offset)
        eval_gradient(vc.dims, dp, vc.data[0] + offset, grad)
        FIT_eval_transfer_with_light(dt, dvs, grad,
                vri.light_dir, vri.light_rgba,
                im.rgba, vri.n_fits,
                vri.fits, vri.field_table_ids, vri.grey_opacity)
        for j in range(3):
            dp[j] += ds[j]
    free(grad)

cdef class star_kdtree_container:
    cdef kdtree_utils.kdtree *tree
    cdef public np.float64_t sigma
    cdef public np.float64_t coeff

    def __init__(self):
        self.tree = kdtree_utils.kd_create(3)

    def add_points(self,
                   np.ndarray[np.float64_t, ndim=1] pos_x,
                   np.ndarray[np.float64_t, ndim=1] pos_y,
                   np.ndarray[np.float64_t, ndim=1] pos_z,
                   np.ndarray[np.float64_t, ndim=2] star_colors):
        cdef int i
        cdef np.float64_t *pointer = <np.float64_t *> star_colors.data
        for i in range(pos_x.shape[0]):
            kdtree_utils.kd_insert3(self.tree,
                pos_x[i], pos_y[i], pos_z[i], <void *> (pointer + i*3))

    def __dealloc__(self):
        kdtree_utils.kd_free(self.tree)

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef void volume_render_stars_sampler(
                 VolumeContainer *vc,
                 np.float64_t v_pos[3],
                 np.float64_t v_dir[3],
                 np.float64_t enter_t,
                 np.float64_t exit_t,
                 int index[3],
                 void *data) nogil:
    cdef ImageAccumulator *im = <ImageAccumulator *> data
    cdef VolumeRenderAccumulator *vri = <VolumeRenderAccumulator *> \
            im.supp_data
    cdef kdtree_utils.kdres *ballq = NULL
    # we assume this has vertex-centered data.
    cdef int offset = index[0] * (vc.dims[1] + 1) * (vc.dims[2] + 1) \
                    + index[1] * (vc.dims[2] + 1) + index[2]
    cdef np.float64_t slopes[6]
    cdef np.float64_t dp[3]
    cdef np.float64_t ds[3]
    cdef np.float64_t dt = (exit_t - enter_t) / vri.n_samples
    cdef np.float64_t dvs[6]
    cdef np.float64_t cell_left[3]
    cdef np.float64_t local_dds[3]
    cdef np.float64_t pos[3]
    cdef int nstars, i, j
    cdef np.float64_t *colors = NULL
    cdef np.float64_t gexp, gaussian, px, py, pz
    px = py = pz = -1
    for i in range(3):
        dp[i] = (enter_t + 0.5 * dt) * v_dir[i] + v_pos[i]
        dp[i] -= index[i] * vc.dds[i] + vc.left_edge[i]
        dp[i] *= vc.idds[i]
        ds[i] = v_dir[i] * vc.idds[i] * dt
    for i in range(vc.n_fields):
        slopes[i] = offset_interpolate(vc.dims, dp,
                        vc.data[i] + offset)
    cdef np.float64_t temp
    # Now we get the ball-tree result for the stars near our cell center.
    for i in range(3):
        cell_left[i] = index[i] * vc.dds[i] + vc.left_edge[i]
        pos[i] = (enter_t + 0.5 * dt) * v_dir[i] + v_pos[i]
        local_dds[i] = v_dir[i] * dt
    ballq = kdtree_utils.kd_nearest_range3(
        vri.star_list, cell_left[0] + vc.dds[0]*0.5,
                        cell_left[1] + vc.dds[1]*0.5,
                        cell_left[2] + vc.dds[2]*0.5,
                        vri.star_er + 0.9*vc.dds[0])
                                    # ~0.866 + a bit

    nstars = kdtree_utils.kd_res_size(ballq)
    for i in range(vc.n_fields):
        temp = slopes[i]
        slopes[i] -= offset_interpolate(vc.dims, dp,
                         vc.data[i] + offset)
        slopes[i] *= -1.0/vri.n_samples
        dvs[i] = temp
    for _ in range(vri.n_samples):
        # Now we add the contribution from stars
        kdtree_utils.kd_res_rewind(ballq)
        for i in range(nstars):
            kdtree_utils.kd_res_item3(ballq, &px, &py, &pz)
            colors = <np.float64_t *> kdtree_utils.kd_res_item_data(ballq)
            kdtree_utils.kd_res_next(ballq)
            gexp = (px - pos[0])*(px - pos[0]) \
                 + (py - pos[1])*(py - pos[1]) \
                 + (pz - pos[2])*(pz - pos[2])
            gaussian = vri.star_coeff * exp(-gexp/vri.star_sigma_num)
            for j in range(3): im.rgba[j] += gaussian*dt*colors[j]
        for i in range(3):
            pos[i] += local_dds[i]
        FIT_eval_transfer(dt, dvs, im.rgba, vri.n_fits, vri.fits,
                          vri.field_table_ids, vri.grey_opacity)
        for i in range(vc.n_fields):
            dvs[i] += slopes[i]
    kdtree_utils.kd_res_free(ballq)

cdef class VolumeRenderSampler(ImageSampler):
    cdef VolumeRenderAccumulator *vra
    cdef public object tf_obj
    cdef public object my_field_tables
    cdef kdtree_utils.kdtree **trees
    cdef object tree_containers
    def __cinit__(self,
                  np.ndarray vp_pos,
                  np.ndarray vp_dir,
                  np.ndarray[np.float64_t, ndim=1] center,
                  bounds,
                  np.ndarray[np.float64_t, ndim=3] image,
                  np.ndarray[np.float64_t, ndim=1] x_vec,
                  np.ndarray[np.float64_t, ndim=1] y_vec,
                  np.ndarray[np.float64_t, ndim=1] width,
                  tf_obj, n_samples = 10,
                  star_list = None, **kwargs):
        ImageSampler.__init__(self, vp_pos, vp_dir, center, bounds, image,
                               x_vec, y_vec, width, **kwargs)
        cdef int i
        cdef np.ndarray[np.float64_t, ndim=1] temp
        # Now we handle tf_obj
        self.vra = <VolumeRenderAccumulator *> \
            malloc(sizeof(VolumeRenderAccumulator))
        self.vra.fits = <FieldInterpolationTable *> \
            malloc(sizeof(FieldInterpolationTable) * 6)
        self.vra.n_fits = tf_obj.n_field_tables
        assert(self.vra.n_fits <= 6)
        self.vra.grey_opacity = getattr(tf_obj, "grey_opacity", 0)
        self.vra.n_samples = n_samples
        self.my_field_tables = []
        for i in range(self.vra.n_fits):
            temp = tf_obj.tables[i].y
            FIT_initialize_table(&self.vra.fits[i],
                      temp.shape[0],
                      <np.float64_t *> temp.data,
                      tf_obj.tables[i].x_bounds[0],
                      tf_obj.tables[i].x_bounds[1],
                      tf_obj.field_ids[i], tf_obj.weight_field_ids[i],
                      tf_obj.weight_table_ids[i])
            self.my_field_tables.append((tf_obj.tables[i],
                                         tf_obj.tables[i].y))
        for i in range(6):
            self.vra.field_table_ids[i] = tf_obj.field_table_ids[i]
        self.supp_data = <void *> self.vra
        cdef star_kdtree_container skdc
        self.tree_containers = star_list
        if star_list is None:
            self.trees = NULL
        else:
            self.trees = <kdtree_utils.kdtree **> malloc(
                sizeof(kdtree_utils.kdtree*) * len(star_list))
            for i in range(len(star_list)):
                skdc = star_list[i]
                self.trees[i] = skdc.tree

    cdef void setup(self, PartitionedGrid pg):
        cdef star_kdtree_container star_tree
        if self.trees == NULL:
            self.sampler = volume_render_sampler
        else:
            star_tree = self.tree_containers[pg.parent_grid_id]
            self.vra.star_list = self.trees[pg.parent_grid_id]
            self.vra.star_sigma_num = 2.0*star_tree.sigma**2.0
            self.vra.star_er = 2.326 * star_tree.sigma
            self.vra.star_coeff = star_tree.coeff
            self.sampler = volume_render_stars_sampler

    def __dealloc__(self):
        for i in range(self.vra.n_fits):
            free(self.vra.fits[i].d0)
            free(self.vra.fits[i].dy)
        free(self.vra.fits)
        free(self.vra)

cdef class LightSourceRenderSampler(ImageSampler):
    cdef VolumeRenderAccumulator *vra
    cdef public object tf_obj
    cdef public object my_field_tables
    def __cinit__(self,
                  np.ndarray vp_pos,
                  np.ndarray vp_dir,
                  np.ndarray[np.float64_t, ndim=1] center,
                  bounds,
                  np.ndarray[np.float64_t, ndim=3] image,
                  np.ndarray[np.float64_t, ndim=1] x_vec,
                  np.ndarray[np.float64_t, ndim=1] y_vec,
                  np.ndarray[np.float64_t, ndim=1] width,
                  tf_obj, n_samples = 10,
                  light_dir=[1.,1.,1.],
                  light_rgba=[1.,1.,1.,1.],
                  **kwargs):
        ImageSampler.__init__(self, vp_pos, vp_dir, center, bounds, image,
                               x_vec, y_vec, width, **kwargs)
        cdef int i
        cdef np.ndarray[np.float64_t, ndim=1] temp
        # Now we handle tf_obj
        self.vra = <VolumeRenderAccumulator *> \
            malloc(sizeof(VolumeRenderAccumulator))
        self.vra.fits = <FieldInterpolationTable *> \
            malloc(sizeof(FieldInterpolationTable) * 6)
        self.vra.n_fits = tf_obj.n_field_tables
        assert(self.vra.n_fits <= 6)
        self.vra.grey_opacity = getattr(tf_obj, "grey_opacity", 0)
        self.vra.n_samples = n_samples
        self.vra.light_dir = <np.float64_t *> malloc(sizeof(np.float64_t) * 3)
        self.vra.light_rgba = <np.float64_t *> malloc(sizeof(np.float64_t) * 4)
        light_dir /= np.sqrt(light_dir[0]**2 + light_dir[1]**2 + light_dir[2]**2)
        for i in range(3):
            self.vra.light_dir[i] = light_dir[i]
        for i in range(4):
            self.vra.light_rgba[i] = light_rgba[i]
        self.my_field_tables = []
        for i in range(self.vra.n_fits):
            temp = tf_obj.tables[i].y
            FIT_initialize_table(&self.vra.fits[i],
                      temp.shape[0],
                      <np.float64_t *> temp.data,
                      tf_obj.tables[i].x_bounds[0],
                      tf_obj.tables[i].x_bounds[1],
                      tf_obj.field_ids[i], tf_obj.weight_field_ids[i],
                      tf_obj.weight_table_ids[i])
            self.my_field_tables.append((tf_obj.tables[i],
                                         tf_obj.tables[i].y))
        for i in range(6):
            self.vra.field_table_ids[i] = tf_obj.field_table_ids[i]
        self.supp_data = <void *> self.vra

    cdef void setup(self, PartitionedGrid pg):
        self.sampler = volume_render_gradient_sampler

    def __dealloc__(self):
        for i in range(self.vra.n_fits):
            free(self.vra.fits[i].d0)
            free(self.vra.fits[i].dy)
        free(self.vra.light_dir)
        free(self.vra.light_rgba)
        free(self.vra.fits)
        free(self.vra)


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.cdivision(True)
cdef int walk_volume(VolumeContainer *vc,
                     np.float64_t v_pos[3],
                     np.float64_t v_dir[3],
                     sampler_function *sampler,
                     void *data,
                     np.float64_t *return_t = NULL,
                     np.float64_t max_t = 1.0) nogil:
    cdef int cur_ind[3]
    cdef int step[3]
    cdef int x, y, i, hit, direction
    cdef np.float64_t intersect_t = 1.1
    cdef np.float64_t iv_dir[3]
    cdef np.float64_t tmax[3]
    cdef np.float64_t tdelta[3]
    cdef np.float64_t exit_t = -1.0, enter_t = -1.0
    cdef np.float64_t tl, temp_x, temp_y = -1
    if max_t > 1.0: max_t = 1.0
    direction = -1
    if vc.left_edge[0] <= v_pos[0] and v_pos[0] <= vc.right_edge[0] and \
       vc.left_edge[1] <= v_pos[1] and v_pos[1] <= vc.right_edge[1] and \
       vc.left_edge[2] <= v_pos[2] and v_pos[2] <= vc.right_edge[2]:
        intersect_t = 0.0
        direction = 3
    for i in range(3):
        if (v_dir[i] < 0):
            step[i] = -1
        elif (v_dir[i] == 0.0):
            step[i] = 0
            continue
        else:
            step[i] = 1
        iv_dir[i] = 1.0/v_dir[i]
        if direction == 3: continue
        x = (i+1) % 3
        y = (i+2) % 3
        if step[i] > 0:
            tl = (vc.left_edge[i] - v_pos[i])*iv_dir[i]
        else:
            tl = (vc.right_edge[i] - v_pos[i])*iv_dir[i]
        temp_x = (v_pos[x] + tl*v_dir[x])
        temp_y = (v_pos[y] + tl*v_dir[y])
        if fabs(temp_x - vc.left_edge[x]) < 1e-10*vc.dds[x]:
            temp_x = vc.left_edge[x]
        elif fabs(temp_x - vc.right_edge[x]) < 1e-10*vc.dds[x]:
            temp_x = vc.right_edge[x]
        if fabs(temp_y - vc.left_edge[y]) < 1e-10*vc.dds[y]:
            temp_y = vc.left_edge[y]
        elif fabs(temp_y - vc.right_edge[y]) < 1e-10*vc.dds[y]:
            temp_y = vc.right_edge[y]
        if vc.left_edge[x] <= temp_x and temp_x <= vc.right_edge[x] and \
           vc.left_edge[y] <= temp_y and temp_y <= vc.right_edge[y] and \
           0.0 <= tl and tl < intersect_t:
            direction = i
            intersect_t = tl
    if enter_t >= 0.0: intersect_t = enter_t 
    if not ((0.0 <= intersect_t) and (intersect_t < max_t)): return 0
    for i in range(3):
        # Two things have to be set inside this loop.
        # cur_ind[i], the current index of the grid cell the ray is in
        # tmax[i], the 't' until it crosses out of the grid cell
        tdelta[i] = step[i] * iv_dir[i] * vc.dds[i]
        if i == direction and step[i] > 0:
            # Intersection with the left face in this direction
            cur_ind[i] = 0
        elif i == direction and step[i] < 0:
            # Intersection with the right face in this direction
            cur_ind[i] = vc.dims[i] - 1
        else:
            # We are somewhere in the middle of the face
            temp_x = intersect_t * v_dir[i] + v_pos[i] # current position
            temp_y = ((temp_x - vc.left_edge[i])*vc.idds[i])
            cur_ind[i] =  <int> (floor(temp_y))
        if step[i] > 0:
            temp_y = (cur_ind[i] + 1) * vc.dds[i] + vc.left_edge[i]
        elif step[i] < 0:
            temp_y = cur_ind[i] * vc.dds[i] + vc.left_edge[i]
        tmax[i] = (temp_y - v_pos[i]) * iv_dir[i]
        if step[i] == 0:
            tmax[i] = 1e60
    # We have to jumpstart our calculation
    for i in range(3):
        if cur_ind[i] == vc.dims[i] and step[i] >= 0:
            return 0
        if cur_ind[i] == -1 and step[i] <= -1:
            return 0
    enter_t = intersect_t
    hit = 0
    while 1:
        hit += 1
        if tmax[0] < tmax[1]:
            if tmax[0] < tmax[2]:
                i = 0
            else:
                i = 2
        else:
            if tmax[1] < tmax[2]:
                i = 1
            else:
                i = 2
        exit_t = fmin(tmax[i], max_t)
        sampler(vc, v_pos, v_dir, enter_t, exit_t, cur_ind, data)
        cur_ind[i] += step[i]
        enter_t = tmax[i]
        tmax[i] += tdelta[i]
        if cur_ind[i] < 0 or cur_ind[i] >= vc.dims[i] or enter_t >= max_t:
            break
    if return_t != NULL: return_t[0] = exit_t
    return hit

def hp_pix2vec_nest(long nside, long ipix):
    raise NotImplementedError
    cdef double v[3]
    healpix_interface.pix2vec_nest(nside, ipix, v)
    cdef np.ndarray[np.float64_t, ndim=1] tr = np.empty((3,), dtype='float64')
    tr[0] = v[0]
    tr[1] = v[1]
    tr[2] = v[2]
    return tr

def arr_pix2vec_nest(long nside,
                     np.ndarray[np.int64_t, ndim=1] aipix):
    raise NotImplementedError
    cdef int n = aipix.shape[0]
    cdef int i
    cdef double v[3]
    cdef long ipix
    cdef np.ndarray[np.float64_t, ndim=2] tr = np.zeros((n, 3), dtype='float64')
    for i in range(n):
        ipix = aipix[i]
        healpix_interface.pix2vec_nest(nside, ipix, v)
        tr[i,0] = v[0]
        tr[i,1] = v[1]
        tr[i,2] = v[2]
    return tr

def hp_vec2pix_nest(long nside, double x, double y, double z):
    raise NotImplementedError
    cdef double v[3]
    v[0] = x
    v[1] = y
    v[2] = z
    cdef long ipix
    healpix_interface.vec2pix_nest(nside, v, &ipix)
    return ipix

def arr_vec2pix_nest(long nside,
                     np.ndarray[np.float64_t, ndim=1] x,
                     np.ndarray[np.float64_t, ndim=1] y,
                     np.ndarray[np.float64_t, ndim=1] z):
    raise NotImplementedError
    cdef int n = x.shape[0]
    cdef int i
    cdef double v[3]
    cdef long ipix
    cdef np.ndarray[np.int64_t, ndim=1] tr = np.zeros(n, dtype='int64')
    for i in range(n):
        v[0] = x[i]
        v[1] = y[i]
        v[2] = z[i]
        healpix_interface.vec2pix_nest(nside, v, &ipix)
        tr[i] = ipix
    return tr

def hp_pix2ang_nest(long nside, long ipnest):
    raise NotImplementedError
    cdef double theta, phi
    healpix_interface.pix2ang_nest(nside, ipnest, &theta, &phi)
    return (theta, phi)

def arr_pix2ang_nest(long nside, np.ndarray[np.int64_t, ndim=1] aipnest):
    raise NotImplementedError
    cdef int n = aipnest.shape[0]
    cdef int i
    cdef long ipnest
    cdef np.ndarray[np.float64_t, ndim=2] tr = np.zeros((n, 2), dtype='float64')
    cdef double theta, phi
    for i in range(n):
        ipnest = aipnest[i]
        healpix_interface.pix2ang_nest(nside, ipnest, &theta, &phi)
        tr[i,0] = theta
        tr[i,1] = phi
    return tr

def hp_ang2pix_nest(long nside, double theta, double phi):
    raise NotImplementedError
    cdef long ipix
    healpix_interface.ang2pix_nest(nside, theta, phi, &ipix)
    return ipix

def arr_ang2pix_nest(long nside,
                     np.ndarray[np.float64_t, ndim=1] atheta,
                     np.ndarray[np.float64_t, ndim=1] aphi):
    raise NotImplementedError
    cdef int n = atheta.shape[0]
    cdef int i
    cdef long ipnest
    cdef np.ndarray[np.int64_t, ndim=1] tr = np.zeros(n, dtype='int64')
    cdef double theta, phi
    for i in range(n):
        theta = atheta[i]
        phi = aphi[i]
        healpix_interface.ang2pix_nest(nside, theta, phi, &ipnest)
        tr[i] = ipnest
    return tr

@cython.boundscheck(False)
@cython.cdivision(False)
@cython.wraparound(False)
def pixelize_healpix(long nside,
                     np.ndarray[np.float64_t, ndim=1] values,
                     long ntheta, long nphi,
                     np.ndarray[np.float64_t, ndim=2] irotation):
    raise NotImplementedError
    # We will first to pix2vec, rotate, then calculate the angle
    cdef int i, j, thetai, phii
    cdef long ipix
    cdef double v0[3], v1[3]
    cdef double pi = 3.1415926
    cdef np.float64_t pi2 = pi/2.0
    cdef np.float64_t phi, theta
    cdef np.ndarray[np.float64_t, ndim=2] results
    cdef np.ndarray[np.int32_t, ndim=2] count
    results = np.zeros((ntheta, nphi), dtype="float64")
    count = np.zeros((ntheta, nphi), dtype="int32")

    cdef np.float64_t phi0 = 0
    cdef np.float64_t dphi = 2.0 * pi/(nphi-1)

    cdef np.float64_t theta0 = 0
    cdef np.float64_t dtheta = pi/(ntheta-1)
    # We assume these are the rotated theta and phi
    for thetai in range(ntheta):
        theta = theta0 + dtheta * thetai
        for phii in range(nphi):
            phi = phi0 + dphi * phii
            # We have our rotated vector
            v1[0] = cos(phi) * sin(theta)
            v1[1] = sin(phi) * sin(theta)
            v1[2] = cos(theta)
            # Now we rotate back
            for i in range(3):
                v0[i] = 0
                for j in range(3):
                    v0[i] += v1[j] * irotation[j,i]
            # Get the pixel this vector is inside
            healpix_interface.vec2pix_nest(nside, v0, &ipix)
            results[thetai, phii] = values[ipix]
            count[i, j] += 1
    return results, count
    #for i in range(ntheta):
    #    for j in range(nphi):
    #        if count[i,j] > 0:
    #            results[i,j] /= count[i,j]
    #return results, count

def healpix_aitoff_proj(np.ndarray[np.float64_t, ndim=1] pix_image,
                        long nside,
                        np.ndarray[np.float64_t, ndim=2] image,
                        np.ndarray[np.float64_t, ndim=2] irotation):
    raise NotImplementedError
    cdef double pi = np.pi
    cdef int i, j, k, l
    cdef np.float64_t x, y, z, zb
    cdef np.float64_t dx, dy, inside
    cdef double v0[3], v1[3]
    dx = 2.0 / (image.shape[1] - 1)
    dy = 2.0 / (image.shape[0] - 1)
    cdef np.float64_t s2 = sqrt(2.0)
    cdef long ipix
    for i in range(image.shape[1]):
        x = (-1.0 + i*dx)*s2*2.0
        for j in range(image.shape[0]):
            y = (-1.0 + j * dy)*s2
            zb = (x*x/8.0 + y*y/2.0 - 1.0)
            if zb > 0: continue
            z = (1.0 - (x/4.0)**2.0 - (y/2.0)**2.0)
            z = z**0.5
            # Longitude
            phi = (2.0*atan(z*x/(2.0 * (2.0*z*z-1.0))) + pi)
            # Latitude
            # We shift it into co-latitude
            theta = (asin(z*y) + pi/2.0)
            # Now to account for rotation we translate into vectors
            v1[0] = cos(phi) * sin(theta)
            v1[1] = sin(phi) * sin(theta)
            v1[2] = cos(theta)
            for k in range(3):
                v0[k] = 0
                for l in range(3):
                    v0[k] += v1[l] * irotation[l,k]
            healpix_interface.vec2pix_nest(nside, v0, &ipix)
            #print "Rotated", v0[0], v0[1], v0[2], v1[0], v1[1], v1[2], ipix, pix_image[ipix]
            image[j, i] = pix_image[ipix]

def arr_fisheye_vectors(int resolution, np.float64_t fov, int nimx=1, int
        nimy=1, int nimi=0, int nimj=0, np.float64_t off_theta=0.0, np.float64_t
        off_phi=0.0):
    # We now follow figures 4-7 of:
    # http://paulbourke.net/miscellaneous/domefisheye/fisheye/
    # ...but all in Cython.
    cdef np.ndarray[np.float64_t, ndim=3] vp
    cdef int i, j
    cdef np.float64_t r, phi, theta, px, py
    cdef np.float64_t fov_rad = fov * np.pi / 180.0
    cdef int nx = resolution/nimx
    cdef int ny = resolution/nimy
    vp = np.zeros((nx,ny, 3), dtype="float64")
    for i in range(nx):
        px = (2.0 * (nimi*nx + i)) / resolution - 1.0
        for j in range(ny):
            py = (2.0 * (nimj*ny + j)) / resolution - 1.0
            r = (px*px + py*py)**0.5
            if r > 1.01:
                vp[i,j,0] = vp[i,j,1] = vp[i,j,2] = 0.0
                continue
            phi = atan2(py, px)
            theta = r * fov_rad / 2.0
            theta += off_theta
            phi += off_phi
            vp[i,j,0] = sin(theta) * cos(phi)
            vp[i,j,1] = sin(theta) * sin(phi)
            vp[i,j,2] = cos(theta)
    return vp


