"""
TODO: Extend it in order to run one script for scipy and numpy
"""
from mpi4py import MPI

comm = MPI.COMM_WORLD
rank = comm.Get_rank()
size = comm.Get_size()

print('scipy: Hello from process {} out of {}'.format(rank, size))
