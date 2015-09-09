# cython: c_string_type=unicode, c_string_encoding=utf8
from __future__ import print_function, absolute_import
import sys
cimport cython
from cython.operator cimport dereference as deref, preincrement as incr
from libcpp.string cimport string
from cpython.array cimport array as pyarray
from cpython cimport array as pyarray_master
from pytraj.cpp_options import set_world_silent # turn on and off cpptraj's stdout

import numpy as np
from pytraj.utils.check_and_assert import is_int, is_array
from pytraj.compat import set
from pytraj.cpptraj_dict import ParmFormatDict
from pytraj.externals.six import PY2, PY3, string_types
from pytraj.utils.check_and_assert import is_int

PY2 = sys.version_info[0] == 2
PY3 = sys.version_info[0] == 3

if PY3:
    string_types = str
else:
    string_types = basestring

__all__ = ['Topology', 'ParmFile']

cdef class Topology:
    def __cinit__(self, *args):
        """
        args = filename or Topology instance
        """
        #cdef TopologyList toplist = TopologyList()
        cdef Topology tp
        cdef string filename
        self.thisptr = new _Topology()

        # I dont make default py_free_mem (True) in __cinit__ since
        # when passing something like top = Topology(filename), Python/Cython
        # would think "filename" is value of py_free_mem
        self.py_free_mem = True

        if not args:
            #print "there is no args" # for debug
            # make empty Topology instance
            pass
        else:
            if len(args) == 1:
                if isinstance(args[0], Topology):
                    tp = args[0]
                    self.thisptr[0] =  tp.thisptr[0]
                else:
                    raise ValueError()
            else:
                raise ValueError()

    def __dealloc__(self):
        if self.py_free_mem and self.thisptr:
            del self.thisptr

    def __str__(self):
        box = self.box
        if box.has_box():
            box_txt = "PBC with box type = %s" % box.type
        else:
            box_txt = "non-PBC"
         
        tmp = "<%s: %s atoms, %s residues, %s mols, %s>" % (
                self.__class__.__name__,
                self.n_atoms,
                self.n_residues,
                self.n_mols,
                box_txt)
        return tmp

    def __repr__(self):
        return self.__str__()

    def __len__(self):
        return self.n_atoms

    def __mul__(self, int n_times):
        cdef int i
        t = self.copy()

        for i in range(n_times-1):
            t.join(self.copy())
        return t

    def __add__(self, Topology other):
        '''order matters

        Examples
        --------
        >>> top0 = pt.load_topology('t0.parm7')
        >>> top1 = pt.load_topology('t1.parm7')
        >>> top2 = top0 + top1
        '''
        new_top = self.copy()
        new_top.join(other)
        return new_top

    def __iadd__(self, Topology other):
        self.join(other)
        return self

    def load(self, string filename):
        """loading Topology from filename

        filename : {str}

        if Topology instance is not empty, it will be still replaced by new one

        # seriously why do we need this method?
        >>> top = Topology("./data/Tc5b.top")
        >>> # replace old with new topology
        >>> top.load("./data/HP36.top")
        >>> # why not using "top = Topology("./data/HP36.top")"?
        """
        del self.thisptr
        self = Topology(filename)

    def copy(self, *args):
        """return a copy of 'self' or copy from 'other' to 'self'
        TODO : add more doc
        """
        cdef Topology tmp
        cdef Topology other

        if not args:
            # make a copy of 'self'
            tmp = Topology()
            tmp.thisptr[0] = self.thisptr[0]
            return tmp
        elif isinstance(args[0], Topology):
            # copy other Topology instance to "self"
            # no error? really?
            other = args[0]
            self.thisptr[0] = other.thisptr[0]

    def __getitem__(self, idx):
        """return an Atom, a list of Atom or a new Topology

        Returns
        -------
        an Atom if idx is an integer
        a new Topology if idx a string mask
        other cases: a list of Atoms

        Examples
        --------
        In [31]: top[0]
        Out[31]: <N-atom, resnum=0, n_bonds=4>
        """

        cdef Atom atom 
        cdef AtomMask atm
        cdef Residue res
        cdef int i
        cdef list alist = []

        if is_int(idx):
            # need to explicitly cast to int
            i = <int> idx
            atom = Atom()
            if i  >= 0:
                atom.thisptr[0] = self.thisptr.index_opr(i)
            else:
                # negative indexing
                atom.thisptr[0] = self.thisptr.index_opr(self.n_atoms + i)
            return atom
        elif isinstance(idx, string_types):
            # return atom object iterator with given mask
            # self(idx) return AtomMask object
            return self._get_new_from_mask(idx)
        elif isinstance(idx, AtomMask):
            atm = <AtomMask> idx
            # return atom object iterator with given mask
            # self(idx) return AtomMask object
            alist = [self[i] for i in atm._indices_view]
        elif isinstance(idx, (list, tuple)) or is_array(idx):
            alist = [self[i] for i in idx]
        elif isinstance(idx, slice):
            # does not have memory efficiency with large Topology
            # (since we convert to atom list first)
            alist = self.atomlist[idx]
        elif isinstance(idx, Residue):
            res = idx
            return self[res.first_atom_idx : res.last_atom_idx]
        elif isinstance(idx, Molecule):
            mol = idx
            return self[mol.begin_atom: mol.end_atom]
        else:
            raise NotImplementedError("")
        if len(alist) == 1:
            return alist[0]
        else:
            return alist

    def __call__(self, mask, *args, **kwd):
        """intended to use with Frame indexing
        Return : AtomMask object
        >>> frame[top("@CA")]
        """
        cdef AtomMask atm = AtomMask(mask)
        self.set_integer_mask(atm)
        return atm

    def __iter__(self):
        return self.atoms

    def select(self, mask):
        """return AtomMask object

        Examples
        --------
        >>> import pytraj as pt
        >>> atm = traj.top.select("@CA")
        >>> pt.rmsd(traj, mask=atm)

        Notes
        -----
            support openmp for distance-based atommask selction
        """
        return self(mask).indices

    property atoms:
        def __get__(self):
            cdef Atom atom
            cdef atom_iterator it

            it = self.thisptr.begin()
            while it != self.thisptr.end():
                atom = Atom()
                atom.thisptr[0] = deref(it)
                yield atom
                incr(it)

    property residues:
        def __get__(self):
            cdef Residue res
            cdef res_iterator it
            it = self.thisptr.ResStart()

            while it != self.thisptr.ResEnd():
                res = Residue()
                res.thisptr[0] = deref(it)
                yield res
                incr(it)
        
    property mols:
        def __get__(self):
            cdef Molecule mol
            cdef mol_iterator it
            it = self.thisptr.MolStart()

            while it != self.thisptr.MolEnd():
                mol = Molecule()
                mol.thisptr[0] = deref(it)
                yield mol
                incr(it)

    def set_reference_frame(self, Frame frame):
        """set reference frame for distance-based atommask selection

        Examples
        --------
            top.set_reference_frame(frame)
            top.select(":3 < :5.0") # select all atoms within 5.0 A to residue 3
        """
        self.thisptr.SetReferenceCoords(frame.thisptr[0])

    def _find_atom_in_residue(self, int res, atname):
        cdef NameType _atomnametype
        if isinstance(atname, string_types):
            _atomnametype = NameType(atname)
        elif isinstance(atname, NameType):
            _atomnametype = <NameType> atname 
        return self.thisptr.FindAtomInResidue(res, _atomnametype.thisptr[0])
    
    property atomlist:
        def __get__(self):
            return list(self.atoms)

    property residuelist:
        def __get__(self):
            return list(self.residues)

    property moleculelist:
        def __get__(self):
            return list(self.mols)

    def summary(self):
        set_world_silent(False)
        self.thisptr.Summary()
        set_world_silent(True)

    def start_new_mol(self):
        self.thisptr.StartNewMol()

    property filename:
        def __get__(self):
            # I want to keep _original_filename so don't need to
            # change other codes
            import os
            return os.path.abspath(self._original_filename)

    property _original_filename:
        def __get__(self):
            '''NOTE: do not delete me
            '''
            cdef FileName filename = FileName()
            filename.thisptr[0] = self.thisptr.OriginalFilename()
            return filename.__str__()

    property n_atoms:
        def __get__(self):
            return self.thisptr.Natom()

    property n_residues:
        def __get__(self):
            return self.thisptr.Nres()

    property n_mols:
        def __get__(self):
            return self.thisptr.Nmol()

    property n_solvents:
        def __get__(self):
            return self.thisptr.Nsolvent()

    property n_frames:
        def __get__(self):
            return self.thisptr.Nframes()

    def set_integer_mask(self, AtomMask atm, Frame frame=Frame()):
        if frame.is_empty():
            return self.thisptr.SetupIntegerMask(atm.thisptr[0])
        else:
            return self.thisptr.SetupIntegerMask(atm.thisptr[0], frame.thisptr[0])

    property box:
        def __get__(self):
            cdef Box box = Box()
            box.thisptr[0] = self.thisptr.ParmBox()
            return box
        def __set__(self, box_or_array):
            cdef Box _box
            if  isinstance(box_or_array, Box):
                _box = box_or_array
            else:
                # try to create box
                _box = Box(box_or_array)
            self.thisptr.SetParmBox(_box.thisptr[0])

    def has_box(self):
        return self.box.has_box()

    def set_nobox(self):
        self.box = Box()

    def _partial_modify_state_by_mask(self, AtomMask m):
        cdef Topology top = Topology()
        top.thisptr[0] = deref(self.thisptr.partialModifyStateByMask(m.thisptr[0]))
        return top

    def _modify_state_by_mask(self, AtomMask m):
        cdef Topology top = Topology()
        top.thisptr[0] = deref(self.thisptr.modifyStateByMask(m.thisptr[0]))
        return top

    def _get_new_from_mask(self, mask=None):
        '''
        >>> top.get_new_with_mask('@CA')
        '''
        if mask is None or mask == "":
            return self
        else:
            atm = self(mask)
            return self._modify_state_by_mask(atm)

    def strip_atoms(Topology self, mask, copy=False):
        """strip atoms with given mask"""
        cdef AtomMask atm
        cdef Topology new_top

        atm = AtomMask(mask)
        self.set_integer_mask(atm)
        if atm.n_atoms == 0:
            raise ValueError("number of stripped atoms must be > 1")
        atm.invert_mask()
        new_top = self._modify_state_by_mask(atm)

        if copy:
            return new_top
        else:
            self.thisptr[0] = new_top.thisptr[0]

    def is_empty(self):
        return self.n_atoms == 0

    def atom_indices(self, mask, *args, **kwd):
        """return atom indices with given mask
        To be the same as cpptraj/Ambertools: we mask indexing starts from 1
        but the return list/array use 0

        Parameters
        ---------
        mask : str
            Atom mask

        Returns
        ------
        indices : Python array
        """
        cdef AtomMask atm = AtomMask(mask)
        self.set_integer_mask(atm)
        return atm.indices

    property atom_names:
        def __get__(self):
            """return unique atom name in Topology
            """
            s = set()
            for atom in self.atoms:
                s.add(atom.name)
            return s

    property residue_names:
        def __get__(self):
            """return unique residue names in Topology
            """
            s = set()
            for residue in self.residues:
                s.add(residue.name)
            return s

    def join(self, Topology top):
        if top is self:
            raise ValueError('must not be your self')
        self.thisptr.AppendTop(top.thisptr[0])
        return self

    property mass:
        def __get__(self):
            """return python array of atom masses"""
            cdef pyarray marray = pyarray('d', [])
            cdef Atom atom

            for atom in self.atoms:
                marray.append(atom.mass)
            return marray

    property change:
        def __get__(self):
            return np.asarray([x.charge for x in self.atoms])

    def indices_bonded_to(self, atom_name):
        """return indices of the number of atoms that each atom bonds to
        Parameters
        ----------
        atom_name : name of the atom
        """
        cdef pyarray arr0 = pyarray('i', [])
        cdef int i, count=0

        # convert to lower case
        atom_name = atom_name.upper()

        for atom in self:
            bond_indices = atom.bonded_indices()
            count = 0
            for i in bond_indices:
                if self[i].name.startswith(atom_name):
                    count += 1
            arr0.append(count)
        return arr0

    def add_bonds(self, cython.integral [:, ::1] indices):
        """add bond for pairs of atoms. 

        Parameters
        ---------
        bond_indices : 2D array_like (must have buffer interface)
            shape=(n_atoms, 2)
        """
        cdef int i
        cdef int j, k

        for i in range(indices.shape[0]):
            j, k = indices[i, :]
            self.thisptr.AddBond(j, k)

    def add_angles(self, cython.integral [:, ::1] indices):
        """add angle for a group of 3 atoms. 

        Parameters
        ---------
        indices : 2D array_like (must have buffer interface),
            shape=(n_atoms, 3)
        """
        cdef int i
        cdef int j, k, n

        for i in range(indices.shape[0]):
            j, k, n = indices[i, :]
            self.thisptr.AddAngle(j, k, n)

    def add_dihedrals(self, cython.integral [:, ::1] indices):
        """add dihedral for a group of 4 atoms. 

        Parameters
        ---------
        indices : 2D array_like (must have buffer interface),
            shape=(n_atoms, 3)
        """
        cdef int i
        cdef int j, k, n, m

        for i in range(indices.shape[0]):
            j, k, n, m = indices[i, :]
            self.thisptr.AddDihedral(j, k, n, m)

    property bonds:
        def __get__(self):
            """return bond iterator"""
            # both noh and with-h bonds
            cdef BondArray bondarray, bondarray_h
            cdef BondType btype = BondType()

            bondarray = self.thisptr.Bonds()
            bondarray_h = self.thisptr.BondsH()
            bondarray.insert(bondarray.end(), bondarray_h.begin(), bondarray_h.end())

            for btype.thisptr[0] in bondarray:
                yield btype

    property angles:
        def __get__(self):
            """return bond iterator"""
            cdef AngleArray anglearray, anglearray_h
            cdef AngleType atype = AngleType()

            anglearray = self.thisptr.Angles()
            anglearray_h = self.thisptr.AnglesH()
            anglearray.insert(anglearray.end(), anglearray_h.begin(), anglearray_h.end())

            for atype.thisptr[0] in anglearray:
                yield atype

    property dihedrals:
        def __get__(self):
            """return dihedral iterator"""
            cdef DihedralArray dharr, dharr_h
            cdef DihedralType dhtype = DihedralType()

            dharr = self.thisptr.Dihedrals()
            dharr_h = self.thisptr.DihedralsH()
            dharr.insert(dharr.end(), dharr_h.begin(), dharr_h.end())

            for dhtype.thisptr[0] in dharr:
                yield dhtype

    property bond_indices:
        def __get__(self):
            return np.asarray([b.indices for b in self.bonds], dtype=np.int64)

    property angle_indices:
        def __get__(self):
            return np.asarray([b.indices for b in self.angles], dtype=np.int64)

    property dihedral_indices:
        def __get__(self):
            return np.asarray([b.indices for b in self.dihedrals], dtype=np.int64)

    property vdw_radii:
        def __get__(self):
            cdef int n_atoms = self.n_atoms
            cdef int i
            cdef pyarray arr = pyarray_master.clone(pyarray('d', []), 
                               n_atoms, zero=True)
            cdef double[:] d_view = arr
            nb = self.NonbondParmType()

            if nb.n_types < 1:
                raise ValueError("don't have LJ parameters")

            for i in range(n_atoms):
                d_view[i] = self.thisptr.GetVDWradius(i)
            return np.asarray(arr)

    def to_dataframe(self):
        import pandas as pd
        cdef:
            int n_atoms = self.n_atoms
            int idx
            Atom atom

        if pd:
            labels = ['resnum', 'resname', 'atomname', 'atomic_number', 'mass']
            mass_arr = np.array(self.mass)
            resnum_arr = np.empty(n_atoms, dtype='i')
            resname_arr = np.empty(n_atoms, dtype='U4')
            atomname_arr= np.empty(n_atoms, 'U4')
            atomicnumber_arr = np.empty(n_atoms, dtype='i4')

            for idx, atom in enumerate(self.atoms):
                # TODO: make faster?
                resnum_arr[idx] = atom.resnum
                resname_arr[idx] = self.residuelist[atom.resnum].name
                atomname_arr[idx] = atom.name
                atomicnumber_arr[idx] = atom.atomic_number

            arr = np.vstack((resnum_arr, resname_arr, atomname_arr, 
                             atomicnumber_arr, mass_arr)).T
            return pd.DataFrame(arr, columns=labels)
        else:
            raise ValueError("must have pandas")

    def to_parmed(self):
        """try to load to ParmEd's Structure
        """
        import parmed as pmd
        return pmd.load_file(self.filename)

    def NonbondParmType(self):
        cdef NonbondParmType nb = NonbondParmType()
        nb.thisptr[0] = self.thisptr.Nonbond()
        return nb

    property _total_charge:
        def __get__(self):
            return sum([atom.charge for atom in self.atoms])

    def save(self, filename=None, format='AMBERPARM'):
        from pytraj.parms.ParmFile import ParmFile
        parm = ParmFile()
        parm.writeparm(filename=filename, top=self, format=format)

    def set_solvent(self, mask):
        '''set ``mask`` as solvent
        '''
        mask = mask.encode()
        self.thisptr.SetSolvent(mask)

cdef class ParmFile:
    def __cinit__(self):
        self.thisptr = new _ParmFile()

    def __dealloc__(self):
        del self.thisptr

    @classmethod
    def formats(cls):
        """return a list of supported parm formats"""
        return ParmFormatDict.keys()

    def readparm(self, filename="", top=Topology(), *args):
        """readparm(Topology top=Topology(), string filename="", "*args)
        Return : None (update `top`)

        top : Topology instance
        filename : str, output filename
        arglist : ArgList instance, optional

        """
        cdef ArgList arglist
        cdef debug = 0
        cdef Topology _top = <Topology> top

        filename = filename.encode()

        if not args:
            self.thisptr.ReadTopology(_top.thisptr[0], filename, debug)
        else:
            arglist = <ArgList> args[0]
            self.thisptr.ReadTopology(_top.thisptr[0], filename, arglist.thisptr[0], debug)

    def writeparm(self, Topology top=Topology(), filename="default.top", 
                  ArgList arglist=ArgList(), format=""):
        cdef int debug = 0
        cdef int err
        # change `for` to upper
        cdef ParmFormatType parmtype 
        filename = filename.encode()
        
        if format== "":
            parmtype = UNKNOWN_PARM
        else:
            try:
                format= format.upper()
                parmtype = ParmFormatDict[format]
            except:
                raise ValueError("supported keywords: ", self.formats)

        if top.is_empty():
            raise ValueError("empty topology")

        err = self.thisptr.WriteTopology(top.thisptr[0], filename, arglist.thisptr[0], parmtype, debug)
        if err == 1:
            raise ValueError("Not supported or failed to write")

    def filename(self):
        cdef FileName filename = FileName()
        #del filename.thisptr
        filename.thisptr[0] = self.thisptr.ParmFilename()
        return filename

cdef class TopologyList:
    def __cinit__(self, py_free_mem=True):
        cdef string filename
        self.thisptr = new _TopologyList()
        self.py_free_mem = py_free_mem

    def __dealloc__(self):
        if self.py_free_mem:
            del self.thisptr

    def __getitem__(self, int idx):
        """return a reference of topology instance in TopologyList with index idx
        Input:
        =====
        idx : int
        """

        try:
           return self.get_parm(idx)
        except:
            raise ValueError("index is out of range? do you have empty list?")

    def __setitem__(self, int idx, Topology other):
        cdef _Topology* topptr
        topptr = self.thisptr.GetParm(idx)
        topptr[0] = other.thisptr[0]

    def get_parm(self, arg):
        # TODO: checkbound
        """Return a Topology instance as a view to Topology instance in TopologyList
        If you made change to this topology, TopologyList would update this change too.
        """

        cdef Topology top = Topology()
        cdef int num
        cdef ArgList argIn
        # Explicitly del this pointer since we later let cpptraj frees memory
        # (we are use memoryview, not gettting a copy)
        del top.thisptr

        # since we pass C++ pointer to top.thisptr, we let cpptraj take care of 
        # freeing memory
        top.py_free_mem = False

        if is_int(arg):
            num = arg
            #top.thisptr[0] = deref(self.thisptr.GetParm(num))
            # use memoryview instead making a copy
            top.thisptr = self.thisptr.GetParm(num)
            if not top.thisptr:
                raise IndexError("Out of bound indexing or empty list")
        if isinstance(arg, ArgList):
            argIn = arg
            # use memoryview instead making a copy
            top.thisptr = self.thisptr.GetParm(argIn.thisptr[0])
            #top.thisptr[0] = deref(self.thisptr.GetParm(argIn.thisptr[0]))
        return top

    def add_parm(self, *args):
        """Add parm file from file or from arglist or from Topology instance
        Input:
        =====
        filename :: str
        or
        arglist :: ArgList instance
        """
        # TODO: what's about adding Topology instance to TopologyList?
        cdef string filename
        cdef ArgList arglist
        cdef Topology top
        cdef Topology newtop

        if len(args) == 1:
            if isinstance(args[0], Topology):
                top = args[0]
                # let cpptraj frees memory since we pass a pointer
                newtop = top.copy()
                newtop.py_free_mem = False
                self.thisptr.AddParm(newtop.thisptr)
            else:
                filename = args[0].encode()
                self.thisptr.AddParmFile(filename)
        elif len(args) == 2:
            filename, arglist = args
            self.thisptr.AddParmFile(filename, arglist.thisptr[0])
