if(NOT DEFINED WW_GIR_FILE)
    message(FATAL_ERROR "WW_GIR_FILE is required")
endif()

file(READ "${WW_GIR_FILE}" _ww_gir)
foreach(_ww_enum PauseEffectCapability TransitionCapability)
    string(FIND "${_ww_gir}" "name=\"${_ww_enum}\"" _ww_enum_pos)
    if(_ww_enum_pos EQUAL -1)
        message(FATAL_ERROR "${_ww_enum} is missing from ${WW_GIR_FILE}")
    endif()
endforeach()
foreach(_ww_method set_pause_effect_capabilities set_transition_capabilities)
    string(FIND "${_ww_gir}" "<method name=\"${_ww_method}\"" _ww_method_pos)
    if(_ww_method_pos EQUAL -1)
        message(FATAL_ERROR "Display.${_ww_method} is missing from ${WW_GIR_FILE}")
    endif()
endforeach()
string(FIND "${_ww_gir}" "<member name=\"pause_blur\"" _ww_pause_blur)
if(_ww_pause_blur EQUAL -1)
    message(FATAL_ERROR
        "PresentationCapability.PAUSE_BLUR is missing from ${WW_GIR_FILE}")
endif()

foreach(_ww_capability fade wipe grow)
    string(FIND "${_ww_gir}" "<member name=\"${_ww_capability}\"" _ww_capability_pos)
    if(_ww_capability_pos EQUAL -1)
        message(FATAL_ERROR
            "PresentationCapability.${_ww_capability} is missing from ${WW_GIR_FILE}")
    endif()
endforeach()

foreach(_ww_transition none fade wipe grow)
    string(FIND "${_ww_gir}" "<member name=\"${_ww_transition}\"" _ww_transition_pos)
    if(_ww_transition_pos EQUAL -1)
        message(FATAL_ERROR
            "TransitionKind.${_ww_transition} is missing from ${WW_GIR_FILE}")
    endif()
endforeach()

string(FIND "${_ww_gir}" "<class name=\"PresentationWidget\"" _ww_presentation_widget)
if(_ww_presentation_widget EQUAL -1)
    message(FATAL_ERROR "PresentationWidget is missing from ${WW_GIR_FILE}")
endif()

foreach(_ww_method set_display stage_shadow set_composition retire_binding frame_ready set_transition clear)
    string(FIND "${_ww_gir}" "<method name=\"${_ww_method}\"" _ww_method_pos)
    if(_ww_method_pos EQUAL -1)
        message(FATAL_ERROR
            "PresentationWidget.${_ww_method} is missing from ${WW_GIR_FILE}")
    endif()
endforeach()

function(_ww_verify_signal_signature signal expected)
    string(FIND "${_ww_gir}" "<glib:signal name=\"${signal}\"" _ww_signal_start)
    if(_ww_signal_start EQUAL -1)
        message(FATAL_ERROR "Signal ${signal} is missing from ${WW_GIR_FILE}")
    endif()
    string(SUBSTRING "${_ww_gir}" ${_ww_signal_start} -1 _ww_signal_tail)
    string(FIND "${_ww_signal_tail}" "</glib:signal>" _ww_signal_end)
    string(SUBSTRING "${_ww_signal_tail}" 0 ${_ww_signal_end} _ww_signal_block)
    string(REGEX REPLACE "[ \t\r\n]+" " " _ww_signal_block "${_ww_signal_block}")
    string(REGEX MATCH "<parameters>.*</parameters>" _ww_parameters "${_ww_signal_block}")
    string(REGEX MATCHALL "<type name=\"[^\"]+\"" _ww_types "${_ww_parameters}")
    list(TRANSFORM _ww_types REPLACE "<type name=\"([^\"]+)\"" "\\1")
    if(NOT "${_ww_types}" STREQUAL "${expected}")
        message(FATAL_ERROR
            "Signal ${signal} has GIR parameter types '${_ww_types}', expected '${expected}'")
    endif()
endfunction()

_ww_verify_signal_signature(binding-ready
    "guint64;guint64;guint64;guint64;guint;guint;guint;guint;guint64;gint;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;guint;gdouble;gdouble;gdouble;gdouble")
_ww_verify_signal_signature(textures-releasing "guint64")
_ww_verify_signal_signature(composition-config
    "guint64;guint64;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;gdouble;guint;gdouble;gdouble;gdouble;gdouble")
_ww_verify_signal_signature(frame-ready "guint64;guint;guint64;gint")
_ww_verify_signal_signature(presentation-snapshot
    "guint64;guint64;guint;guint;gboolean;guint;guint;guint;gdouble;gdouble")
_ww_verify_signal_signature(binding-staged "guint;guint;guint;guint;gint")
