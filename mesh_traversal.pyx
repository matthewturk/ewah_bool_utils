cimport cython
cimport numpy as np
import numpy as np
cimport pyembree.rtcore as rtc
cimport pyembree.rtcore_ray as rtcr
cimport pyembree.rtcore_geometry as rtcg
cimport pyembree.rtcore_scene as rtcs
from grid_traversal cimport ImageSampler

cdef void error_printer(const rtc.RTCError code, const char *_str):
    print "ERROR CAUGHT IN EMBREE"
    rtc.print_error(code)
    print "ERROR MESSAGE:", _str

cdef class EmbreeVolume:

    def __init__(self):
        rtc.rtcInit(NULL)
        rtc.rtcSetErrorFunction(error_printer)
        self.scene_i = rtcs.rtcNewScene(rtcs.RTC_SCENE_STATIC, rtcs.RTC_INTERSECT1)

    def __dealloc__(self):
        rtcs.rtcDeleteScene(self.scene_i)

cdef class MeshSampler(ImageSampler):

    @cython.boundscheck(False)
    @cython.wraparound(False)
    @cython.cdivision(True)
    def __call__(self, EmbreeVolume volume, int num_threads = 0):
        '''

        This function is supposed to cast the rays and return the
        image.

        '''

        pass
