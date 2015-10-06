import unittest
import pytraj as pt
import sys
from pytraj.base import *
from pytraj import Frame
from pytraj import adict
from pytraj import io as mdio
from pytraj.testing import aa_eq
from pytraj.core.cpp_core import Command
from pytraj.core.cpp_core import CpptrajState
from pytraj.compat import izip as zip

text = """
parm ./data/Tc5b.top
trajin ./data/md1_prod.Tc5b.x
rotate x 60 y 120 z 50 @CA
trajout rotated_frame0.x60y120z50.Tc5b.r
"""


def iter_me(obj, n_frames):
    from pytraj._shared_methods import iterframe_master
    it = iterframe_master(obj)
    for idx, frame in enumerate(it):
        pass
    assert idx + 1 == n_frames


class Test(unittest.TestCase):
    def test_cpptraj_file(self):
        from pytraj._shared_methods import iterframe_master
        traj = mdio.iterload("./data/md1_prod.Tc5b.x", "./data/Tc5b.top")
        fname = "./tc5b.rotate.in"
        with open(fname, 'w') as f:
            f.write(text)
        state = mdio.load_cpptraj_file(fname)

    def test_0(self):
        from pytraj._shared_methods import iterframe_master
        traj = mdio.iterload("./data/md1_prod.Tc5b.x", "./data/Tc5b.top")
        fa = traj[:]

        #print("iter traj")
        iter_me(traj, traj.n_frames)
        iter_me(fa, traj.n_frames)

        #print("iter of traj frame_iter")
        iter_me(traj(), traj.n_frames)
        iter_me(fa(), traj.n_frames)

        #print("iter of traj frame_iter with mask")
        iter_me(traj(mask='@CA'), traj.n_frames)
        iter_me(fa(mask='@CA'), traj.n_frames)

        #print("iter list/tuple")
        iter_me([traj, fa], 2 * traj.n_frames)
        iter_me((traj, fa), 2 * traj.n_frames)
        iter_me((traj, (fa[0], )), traj.n_frames + 1)

        #print("iter frame")
        for frame in iterframe_master(traj[0]):
            assert frame.n_atoms == traj.top.n_atoms

        #print("iter frame")
        i = 0
        for frame in iterframe_master([traj, traj[:1]]):
            i += 1
            assert frame.n_atoms == traj.top.n_atoms
        assert i == traj.n_frames + 1

        #print("iter chunk_iter")
        i = 0
        for frame in iterframe_master(traj.iterchunk()):
            i += 1
            assert isinstance(frame, Frame)
        assert i == traj.n_frames

        #print("list of chunk_iter")
        i = 0
        for frame in iterframe_master([traj.iterchunk(), ]):
            i += 1
            assert isinstance(frame, Frame)
        assert i == traj.n_frames

    def test_assert(self):
        from pytraj._shared_methods import iterframe_master as _it_f
        traj = mdio.iterload("./data/md1_prod.Tc5b.x", "./data/Tc5b.top")
        fa = Trajectory.from_iterable(_it_f(traj), top=traj.top)

        for f0, f1 in zip(fa, traj):
            #print(f0[0, :], f1[0, :])
            aa_eq(f0.coords, f1.coords)

    def testTrajectorView(self):
        traj = mdio.iterload("./data/md1_prod.Tc5b.x", "./data/Tc5b.top")
        # make mutable traj
        t0 = traj[:]
        t1 = traj[:]
        indices = [2, 4, 6]
        # iter frame to return a view
        for f in t0.iterframe(frame_indices=indices):
            f.xyz += 1.0
        aa_eq(t0.xyz[indices], traj[indices].xyz + 1.)
        aa_eq(t1.xyz[indices], traj[indices].xyz)


if __name__ == "__main__":
    unittest.main()
