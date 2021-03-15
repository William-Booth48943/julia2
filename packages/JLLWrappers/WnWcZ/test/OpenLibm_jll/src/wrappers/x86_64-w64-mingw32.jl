# Autogenerated wrapper script for OpenLibm_jll for x86_64-w64-mingw32
export libopenlibm

JLLWrappers.@generate_wrapper_header("OpenLibm")
JLLWrappers.@declare_library_product(libopenlibm, "libopenlibm.dll")
JLLWrappers.@declare_library_product(libnonexisting, "libnonexisting.dll")
function __init__()
    JLLWrappers.@generate_init_header()
    JLLWrappers.@init_library_product(
        libopenlibm,
        "bin/libopenlibm.dll",
        RTLD_LAZY | RTLD_DEEPBIND,
    )
    JLLWrappers.@init_library_product(
        libnonexisting,
        "bin/libnonexisting.dll",
        nothing,
    )

    JLLWrappers.@generate_init_footer()
end  # __init__()
