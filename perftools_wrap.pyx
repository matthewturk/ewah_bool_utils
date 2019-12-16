"""
Turn on and off perftools profiling



"""


# For more info:
# https://pygabriel.wordpress.com/2010/04/14/profiling-python-c-extensions/

# prof.pyx
cdef extern from "google/profiler.h":
    void ProfilerStart( char* fname )
    void ProfilerStop()

def profiler_start(char *fname):
    ProfilerStart(<char *>fname)

def profiler_stop():
    ProfilerStop()

