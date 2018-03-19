from functools import partial
from charfbuzz cimport *
from libc.stdlib cimport free, malloc
from typing import Callable, List, Tuple


cdef class glyph_info:
    cdef hb_glyph_info_t _hb_glyph_info
    # could maybe store Buffer to prevent GC

    cdef set(self, hb_glyph_info_t info):
        self._hb_glyph_info = info

    @property
    def codepoint(self):
        return self._hb_glyph_info.codepoint

    @property
    def cluster(self):
        return self._hb_glyph_info.cluster


cdef class glyph_position:
    cdef hb_glyph_position_t _hb_glyph_position
    # could maybe store Buffer to prevent GC

    cdef set(self, hb_glyph_position_t position):
        self._hb_glyph_position = position

    @property
    def position(self):
        return (
            self._hb_glyph_position.x_offset,
            self._hb_glyph_position.y_offset,
            self._hb_glyph_position.x_advance,
            self._hb_glyph_position.y_advance
        )

    @property
    def x_advance(self):
        return self._hb_glyph_position.x_advance

    @property
    def y_advance(self):
        return self._hb_glyph_position.y_advance

    @property
    def x_offset(self):
        return self._hb_glyph_position.x_offset

    @property
    def y_offset(self):
        return self._hb_glyph_position.y_offset


cdef class Buffer:
    cdef hb_buffer_t* _hb_buffer

    def __cinit__(self):
        self._hb_buffer = NULL

    def __dealloc__(self):
        if self._hb_buffer is not NULL:
            hb_buffer_destroy(self._hb_buffer)

    @classmethod
    def create(cls):
        cdef Buffer inst = cls()
        inst._hb_buffer = hb_buffer_create()
        return inst

    @property
    def direction(self) -> str:
        return hb_direction_to_string(
            hb_buffer_get_direction(self._hb_buffer))

    @direction.setter
    def direction(self, value: str):
        cdef bytes packed = value.encode()
        cdef char* cstr = packed
        hb_buffer_set_direction(
            self._hb_buffer, hb_direction_from_string(cstr, -1))

    @property
    def glyph_infos(self) -> List[glyph_info]:
        cdef unsigned int count
        cdef hb_glyph_info_t* glyph_infos = hb_buffer_get_glyph_infos(
            self._hb_buffer, &count)
        cdef list infos = []
        cdef glyph_info info
        cdef unsigned int i
        for i in range(count):
            info = glyph_info()
            info.set(glyph_infos[i])
            infos.append(info)
        return infos

    @property
    def glyph_positions(self) -> List[glyph_position]:
        cdef unsigned int count
        cdef hb_glyph_position_t* glyph_positions = \
            hb_buffer_get_glyph_positions(self._hb_buffer, &count)
        cdef list positions = []
        cdef glyph_position position
        cdef unsigned int i
        for i in range(count):
            position = glyph_position()
            position.set(glyph_positions[i])
            positions.append(position)
        return positions


    @property
    def language(self) -> str:
        return hb_language_to_string(
            hb_buffer_get_language(self._hb_buffer))

    @language.setter
    def language(self, value: str):
        cdef bytes packed = value.encode()
        cdef char* cstr = packed
        hb_buffer_set_language(
            self._hb_buffer, hb_language_from_string(cstr, -1))

    @property
    def script(self) -> str:
        cdef char cstr[5]
        hb_tag_to_string(hb_buffer_get_script(self._hb_buffer), cstr)
        cdef bytes packed = cstr
        return packed.decode()

    @script.setter
    def script(self, value: str):
        cdef bytes packed = value.encode()
        cdef char* cstr = packed
        # all the *_from_string calls should probably be checked and throw an
        # exception if NULL
        hb_buffer_set_script(
            self._hb_buffer, hb_script_from_string(cstr, -1))

    def add_codepoints(self, codepoints: List[int],
                       item_offset: int = None, item_length: int = None) -> None:
        cdef unsigned int size = len(codepoints)
        cdef hb_codepoint_t* hb_codepoints
        if item_offset is None:
            item_offset = 0
        if item_length is None:
            item_length = size
        if not size:
            hb_codepoints = NULL
        else:
            hb_codepoints = <hb_codepoint_t*>malloc(
                size * sizeof(hb_codepoint_t))
            for i in range(size):
                hb_codepoints[i] = codepoints[i]
        hb_buffer_add_codepoints(
            self._hb_buffer, hb_codepoints, size, item_offset, item_length)
        if hb_codepoints is not NULL:
            free(hb_codepoints)

    def add_str(self, text: str,
                item_offset: int = None, item_length: int = None) -> None:
        cdef bytes packed = text.encode('UTF-8')
        cdef unsigned int size = len(packed)
        if item_offset is None:
            item_offset = 0
        if item_length is None:
            item_length = size
        cdef char* cstr = packed
        hb_buffer_add_utf8(
            self._hb_buffer, cstr, size, item_offset, item_length)

    def guess_segment_properties(self) -> None:
        hb_buffer_guess_segment_properties(self._hb_buffer)

cdef hb_user_data_key_t k


cdef hb_blob_t* _reference_table_func(
        hb_face_t* face, hb_tag_t tag, void* user_data):
    cdef Face py_face = <object>(hb_face_get_user_data(face, &k))
    #
    cdef char cstr[5]
    hb_tag_to_string(tag, cstr)
    #
    cdef bytes table = py_face._reference_table_func(
        py_face, <bytes>cstr, <object>user_data)
    if table is None:
        return NULL
    return hb_blob_create(
        table, len(table), HB_MEMORY_MODE_READONLY, NULL, NULL)


cdef class Face:
    cdef hb_face_t* _hb_face
    cdef object _reference_table_func

    def __cinit__(self):
        self._hb_face = NULL

    def __dealloc__(self):
        if self._hb_face is not NULL:
            hb_face_destroy(self._hb_face)
        self._func = None

    """ use bytes/bytearray, not Blob
    @classmethod
    def create(self, blob: Blob, index: int):
        cdef Face inst = cls()
        inst._hb_face = hb_face_create(blob, index)
        return inst
    """

    @classmethod
    def create_for_tables(cls,
                          func: Callable[[
                              Face,
                              bytes,  # tag
                              object  # user_data
                          ], bytes],
                          user_data: object):
        cdef Face inst = cls()
        inst._hb_face = hb_face_create_for_tables(
            _reference_table_func, <void*>user_data, NULL)
        hb_face_set_user_data(inst._hb_face, &k, <void*>inst, NULL, 0)
        inst._reference_table_func = func
        return inst

    @property
    def upem(self) -> int:
        return hb_face_get_upem(self._hb_face)

    @upem.setter
    def upem(self, value: int):
        hb_face_set_upem(self._hb_face, value)


cdef class Font:
    cdef hb_font_t* _hb_font
    # GC bookkeeping
    cdef Face _face
    cdef FontFuncs _ffuncs

    def __cinit__(self):
        self._hb_font = NULL

    def __dealloc__(self):
        if self._hb_font is not NULL:
            hb_font_destroy(self._hb_font)
        self._face = self._ffuncs = None

    @classmethod
    def create(cls, face: Face):
        cdef Font inst = cls()
        inst._hb_font = hb_font_create(face._hb_face)
        inst._face = face
        return inst

    @property
    def face(self):
        return self._face

    @property
    def funcs(self) -> FontFuncs:
        return self._ffuncs

    @funcs.setter
    def funcs(self, ffuncs: FontFuncs):
        hb_font_set_funcs(
            self._hb_font, ffuncs._hb_ffuncs, <void*>self, NULL)
        self._ffuncs = ffuncs

    @property
    def scale(self) -> Tuple[int, int]:
        cdef int x, y
        hb_font_get_scale(self._hb_font, &x, &y)
        return (x, y)

    @scale.setter
    def scale(self, value: Tuple[int, int]):
        x, y = value
        hb_font_set_scale(self._hb_font, x, y)


cdef hb_position_t _glyph_h_advance_func(hb_font_t* font, void* font_data,
                                         hb_codepoint_t glyph,
                                         void* user_data):
    cdef Font py_font = <Font>font_data
    return (<FontFuncs>py_font.funcs)._glyph_h_advance_func(
        py_font, glyph, <object>user_data)


cdef hb_bool_t _glyph_name_func(hb_font_t *font, void *font_data,
                                hb_codepoint_t glyph,
                                char *name, unsigned int size,
                                void *user_data):
    cdef Font py_font = <Font>font_data
    cdef bytes ret = (<FontFuncs>py_font.funcs)._glyph_name_func(
        py_font, glyph, <object>user_data).encode()
    name[0] = ret
    return 1


cdef hb_bool_t _nominal_glyph_func(hb_font_t* font, void* font_data,
                                   hb_codepoint_t unicode,
                                   hb_codepoint_t* glyph,
                                   void* user_data):
    cdef Font py_font = <Font>font_data
    glyph[0] = (<FontFuncs>py_font.funcs)._nominal_glyph_func(
        py_font, unicode, <object>user_data)
    return 1


cdef class FontFuncs:
    cdef hb_font_funcs_t* _hb_ffuncs
    cdef object _glyph_h_advance_func
    cdef object _glyph_name_func
    cdef object _nominal_glyph_func

    def __cinit__(self):
        self._hb_ffuncs = NULL

    def __dealloc__(self):
        if self._hb_ffuncs is not NULL:
            hb_font_funcs_destroy(self._hb_ffuncs)

    @classmethod
    def create(cls):
        cdef FontFuncs inst = cls()
        inst._hb_ffuncs = hb_font_funcs_create()
        return inst

    def set_glyph_h_advance_func(self,
                                 func: Callable[[
                                     Font,
                                     int,  # gid
                                     object,  # user_data
                                 ], int],  # h_advance
                                 user_data: object) -> None:
        hb_font_funcs_set_glyph_h_advance_func(
            self._hb_ffuncs, _glyph_h_advance_func, <void*>user_data, NULL)
        self._glyph_h_advance_func = func

    def set_glyph_name_func(self,
                            func: Callable[[
                                Font,
                                int,  # gid
                                object,  # user_data
                            ], str],  # name
                            user_data: object) -> None:
        hb_font_funcs_set_glyph_name_func(
            self._hb_ffuncs, _glyph_name_func, <void*>user_data, NULL)
        self._glyph_name_func = func

    def set_nominal_glyph_func(self,
                               func: Callable[[
                                   Font,
                                   int,  # unicode
                                   object,  # user_data
                               ], int],  # gid
                               user_data: object) -> None:
        hb_font_funcs_set_nominal_glyph_func(
            self._hb_ffuncs, _nominal_glyph_func, <void*>user_data, NULL)
        self._nominal_glyph_func = func


# features can be enabled/disabled, so this should rather be a dict of
# str: bool
def shape(font: Font, buffer: Buffer, features: List[str] = None) -> None:
    cdef unsigned int size
    cdef hb_feature_t* hb_features
    cdef bytes packed
    cdef char* cstr
    cdef hb_feature_t feat
    if features is None:
        size = 0
        hb_features = NULL
    else:
        size = len(features)
        hb_features = <hb_feature_t*>malloc(size * sizeof(hb_feature_t))
        for i in range(size):
            packed = features[i].encode()
            cstr = packed
            hb_feature_from_string(packed, len(packed), &feat)
            hb_features[i] = feat
    hb_shape(font._hb_font, buffer._hb_buffer, hb_features, size)
    if hb_features is not NULL:
        free(hb_features)