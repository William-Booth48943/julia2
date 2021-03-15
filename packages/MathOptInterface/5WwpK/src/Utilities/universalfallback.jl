"""
    UniversalFallback

The `UniversalFallback` can be applied on a [`MathOptInterface.ModelLike`](@ref)
`model` to create the model `UniversalFallback(model)` supporting *any*
constraint and attribute. This allows to have a specialized implementation in
`model` for performance critical constraints and attributes while still
supporting other attributes with a small performance penalty. Note that `model`
is unaware of constraints and attributes stored by `UniversalFallback` so this
is not appropriate if `model` is an optimizer (for this reason,
[`MathOptInterface.optimize!`](@ref) has not been implemented). In that case,
optimizer bridges should be used instead.
"""
mutable struct UniversalFallback{MT} <: MOI.ModelLike
    model::MT
    objective::Union{MOI.AbstractScalarFunction,Nothing}
    constraints::OrderedDict{Tuple{DataType,DataType},OrderedDict} # See https://github.com/jump-dev/JuMP.jl/issues/1152 and https://github.com/jump-dev/JuMP.jl/issues/2238
    nextconstraintid::Int64
    con_to_name::Dict{CI,String}
    name_to_con::Union{Dict{String,MOI.ConstraintIndex},Nothing}
    optattr::Dict{MOI.AbstractOptimizerAttribute,Any}
    modattr::Dict{MOI.AbstractModelAttribute,Any}
    varattr::Dict{MOI.AbstractVariableAttribute,Dict{VI,Any}}
    conattr::Dict{MOI.AbstractConstraintAttribute,Dict{CI,Any}}
    function UniversalFallback{MT}(model::MOI.ModelLike) where {MT}
        return new{typeof(model)}(
            model,
            nothing,
            OrderedDict{Tuple{DataType,DataType},OrderedDict}(),
            0,
            Dict{CI,String}(),
            nothing,
            Dict{MOI.AbstractOptimizerAttribute,Any}(),
            Dict{MOI.AbstractModelAttribute,Any}(),
            Dict{MOI.AbstractVariableAttribute,Dict{VI,Any}}(),
            Dict{MOI.AbstractConstraintAttribute,Dict{CI,Any}}(),
        )
    end
end
function UniversalFallback(model::MOI.ModelLike)
    return UniversalFallback{typeof(model)}(model)
end

function Base.show(io::IO, U::UniversalFallback)
    s(n) = n == 1 ? "" : "s"
    indent = " "^get(io, :indent, 0)
    MOIU.print_with_acronym(io, summary(U))
    !(U.objective === nothing) && print(io, "\n$(indent)with objective")
    for (attr, name) in (
        (U.constraints, "constraint"),
        (U.optattr, "optimizer attribute"),
        (U.modattr, "model attribute"),
        (U.varattr, "variable attribute"),
        (U.conattr, "constraint attribute"),
    )
        n = length(attr)
        if n > 0
            print(io, "\n$(indent)with $n $name$(s(n))")
        end
    end
    print(io, "\n$(indent)fallback for ")
    return show(IOContext(io, :indent => get(io, :indent, 0) + 2), U.model)
end

function MOI.is_empty(uf::UniversalFallback)
    return MOI.is_empty(uf.model) &&
           uf.objective === nothing &&
           isempty(uf.constraints) &&
           isempty(uf.modattr) &&
           isempty(uf.varattr) &&
           isempty(uf.conattr)
end
function MOI.empty!(uf::UniversalFallback)
    MOI.empty!(uf.model)
    uf.objective = nothing
    empty!(uf.constraints)
    uf.nextconstraintid = 0
    empty!(uf.con_to_name)
    uf.name_to_con = nothing
    empty!(uf.modattr)
    empty!(uf.varattr)
    return empty!(uf.conattr)
end
function MOI.copy_to(uf::UniversalFallback, src::MOI.ModelLike; kws...)
    return MOIU.automatic_copy_to(uf, src; kws...)
end
function supports_default_copy_to(uf::UniversalFallback, copy_names::Bool)
    return supports_default_copy_to(uf.model, copy_names)
end

# References
MOI.is_valid(uf::UniversalFallback, idx::VI) = MOI.is_valid(uf.model, idx)
function MOI.is_valid(uf::UniversalFallback, idx::CI{F,S}) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.is_valid(uf.model, idx)
    else
        haskey(uf.constraints, (F, S)) && haskey(uf.constraints[(F, S)], idx)
    end
end
function MOI.delete(uf::UniversalFallback, ci::CI{F,S}) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.delete(uf.model, ci)
    else
        if !MOI.is_valid(uf, ci)
            throw(MOI.InvalidIndex(ci))
        end
        delete!(uf.constraints[(F, S)], ci)
        delete!(uf.con_to_name, ci)
        uf.name_to_con = nothing
    end
    for d in values(uf.conattr)
        delete!(d, ci)
    end
end
function _remove_variable(
    uf::UniversalFallback,
    constraints::OrderedDict{<:CI{MOI.SingleVariable}},
    vi::VI,
)
    to_delete = keytype(constraints)[]
    for (ci, constraint) in constraints
        f::MOI.SingleVariable = constraint[1]
        if f.variable == vi
            push!(to_delete, ci)
        end
    end
    return MOI.delete(uf, to_delete)
end
function _remove_variable(
    uf::UniversalFallback,
    constraints::OrderedDict{CI{MOI.VectorOfVariables,S}},
    vi::VI,
) where {S}
    to_delete = keytype(constraints)[]
    for (ci, constraint) in constraints
        f::MOI.VectorOfVariables, s = constraint
        if vi in f.variables
            if length(f.variables) > 1
                if MOI.supports_dimension_update(S)
                    constraints[ci] = remove_variable(f, s, vi)
                else
                    throw_delete_variable_in_vov(vi)
                end
            else
                push!(to_delete, ci)
            end
        end
    end
    return MOI.delete(uf, to_delete)
end
function _remove_variable(
    ::UniversalFallback,
    constraints::OrderedDict{<:CI},
    vi::VI,
)
    for (ci, constraint) in constraints
        f, s = constraint
        constraints[ci] = remove_variable(f, s, vi)
    end
end
function _remove_vector_of_variables(
    uf::UniversalFallback,
    constraints::OrderedDict{<:CI{MOI.VectorOfVariables}},
    vis::Vector{VI},
)
    to_delete = keytype(constraints)[]
    for (ci, constraint) in constraints
        f::MOI.VectorOfVariables = constraint[1]
        if vis == f.variables
            push!(to_delete, ci)
        end
    end
    return MOI.delete(uf, to_delete)
end
function _remove_vector_of_variables(
    ::UniversalFallback,
    ::OrderedDict{<:CI},
    ::Vector{VI},
) end
function MOI.delete(uf::UniversalFallback, vi::VI)
    MOI.delete(uf.model, vi)
    for d in values(uf.varattr)
        delete!(d, vi)
    end
    if uf.objective !== nothing
        uf.objective = remove_variable(uf.objective, vi)
    end
    for (_, constraints) in uf.constraints
        _remove_variable(uf, constraints, vi)
    end
end
function MOI.delete(uf::UniversalFallback, vis::Vector{VI})
    MOI.delete(uf.model, vis)
    for d in values(uf.varattr)
        for vi in vis
            delete!(d, vi)
        end
    end
    if uf.objective !== nothing
        uf.objective = remove_variable(uf.objective, vis)
    end
    for (_, constraints) in uf.constraints
        _remove_vector_of_variables(uf, constraints, vis)
        for vi in vis
            _remove_variable(uf, constraints, vi)
        end
    end
end

# Attributes
_get(uf, attr::MOI.AbstractOptimizerAttribute) = uf.optattr[attr]
_get(uf, attr::MOI.AbstractModelAttribute) = uf.modattr[attr]
function _get(uf, attr::MOI.AbstractVariableAttribute, vi::VI)
    attribute_dict = get(uf.varattr, attr, nothing)
    if attribute_dict === nothing
        # It means the attribute is not set to any variable so in particular, it
        # is not set for `vi`
        return nothing
    end
    return get(attribute_dict, vi, nothing)
end
function _get(uf, attr::MOI.AbstractConstraintAttribute, ci::CI)
    attribute_dict = get(uf.conattr, attr, nothing)
    if attribute_dict === nothing
        # It means the attribute is not set to any constraint so in particular,
        # it is not set for `ci`
        return nothing
    end
    return get(attribute_dict, ci, nothing)
end
function _get(
    uf,
    attr::MOI.CanonicalConstraintFunction,
    ci::MOI.ConstraintIndex,
)
    return MOI.get_fallback(uf, attr, ci)
    func = MOI.get(uf, MOI.ConstraintFunction(), ci)
    if is_canonical(func)
        return func
    else
        return canonical(func)
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::Union{MOI.AbstractOptimizerAttribute,MOI.AbstractModelAttribute},
)
    if !MOI.is_copyable(attr) || MOI.supports(uf.model, attr)
        MOI.get(uf.model, attr)
    else
        _get(uf, attr)
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.AbstractConstraintAttribute,
    idx::MOI.ConstraintIndex{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S) &&
       (!MOI.is_copyable(attr) || MOI.supports(uf.model, attr, typeof(idx)))
        MOI.get(uf.model, attr, idx)
    else
        _get(uf, attr, idx)
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.AbstractVariableAttribute,
    idx::MOI.VariableIndex,
)
    if !MOI.is_copyable(attr) || MOI.supports(uf.model, attr, typeof(idx))
        MOI.get(uf.model, attr, idx)
    else
        _get(uf, attr, idx)
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.NumberOfConstraints{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        return MOI.get(uf.model, attr)
    else
        return length(get(
            uf.constraints,
            (F, S),
            OrderedDict{CI{F,S},Tuple{F,S}}(),
        ))
    end
end
function MOI.get(
    uf::UniversalFallback,
    listattr::MOI.ListOfConstraintIndices{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.get(uf.model, listattr)
    else
        collect(keys(get(
            uf.constraints,
            (F, S),
            OrderedDict{CI{F,S},Tuple{F,S}}(),
        )))
    end
end
function MOI.get(uf::UniversalFallback, listattr::MOI.ListOfConstraints)
    list = MOI.get(uf.model, listattr)
    for (FS, constraints) in uf.constraints
        if !isempty(constraints)
            push!(list, FS)
        end
    end
    return list
end
function MOI.get(
    uf::UniversalFallback,
    listattr::MOI.ListOfOptimizerAttributesSet,
)
    list = MOI.get(uf.model, listattr)
    for attr in keys(uf.optattr)
        push!(list, attr)
    end
    return list
end
function MOI.get(uf::UniversalFallback, listattr::MOI.ListOfModelAttributesSet)
    list = MOI.get(uf.model, listattr)
    if uf.objective !== nothing
        push!(list, MOI.ObjectiveFunction{typeof(uf.objective)}())
    end
    for attr in keys(uf.modattr)
        push!(list, attr)
    end
    return list
end
function MOI.get(
    uf::UniversalFallback,
    listattr::MOI.ListOfVariableAttributesSet,
)
    list = MOI.get(uf.model, listattr)
    for attr in keys(uf.varattr)
        push!(list, attr)
    end
    return list
end
function MOI.get(
    uf::UniversalFallback,
    listattr::MOI.ListOfConstraintAttributesSet{F,S},
) where {F,S}
    list = MOI.get(uf.model, listattr)
    for attr in keys(uf.conattr)
        push!(list, attr)
    end
    return list
end

# Objective
function MOI.set(
    uf::UniversalFallback,
    attr::MOI.ObjectiveSense,
    sense::MOI.OptimizationSense,
) where {T}
    if sense == MOI.FEASIBILITY_SENSE
        uf.objective = nothing
    end
    return MOI.set(uf.model, attr, sense)
end
function MOI.get(uf::UniversalFallback, attr::MOI.ObjectiveFunctionType)
    if uf.objective === nothing
        return MOI.get(uf.model, attr)
    else
        return typeof(uf.objective)
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.ObjectiveFunction{F},
)::F where {F}
    if uf.objective === nothing
        return MOI.get(uf.model, attr)
    else
        return uf.objective
    end
end
function MOI.set(
    uf::UniversalFallback,
    attr::MOI.ObjectiveFunction,
    func::MOI.AbstractScalarFunction,
)
    if MOI.supports(uf.model, attr)
        MOI.set(uf.model, attr, func)
        # Clear any fallback objective
        uf.objective = nothing
    else
        uf.objective = copy(func)
        # Clear any `model` objective
        sense = MOI.get(uf.model, MOI.ObjectiveSense())
        MOI.set(uf.model, MOI.ObjectiveSense(), MOI.FEASIBILITY_SENSE)
        MOI.set(uf.model, MOI.ObjectiveSense(), sense)
    end
end

function MOI.modify(
    uf::UniversalFallback,
    obj::MOI.ObjectiveFunction,
    change::MOI.AbstractFunctionModification,
) where {F}
    if uf.objective === nothing
        MOI.modify(uf.model, obj, change)
    else
        uf.objective = modify_function(uf.objective, change)
    end
end

# Name
# The names of constraints not supported by `uf.model` need to be handled
function MOI.set(
    uf::UniversalFallback,
    attr::MOI.ConstraintName,
    ci::CI{F,S},
    name::String,
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.set(uf.model, attr, ci, name)
    else
        uf.con_to_name[ci] = name
        uf.name_to_con = nothing # Invalidate the name map.
    end
    return
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.ConstraintName,
    ci::CI{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        return MOI.get(uf.model, attr, ci)
    else
        return get(uf.con_to_name, ci, EMPTYSTRING)
    end
end

function MOI.get(uf::UniversalFallback, ::Type{VI}, name::String)
    return MOI.get(uf.model, VI, name)
end

check_type_and_multiple_names(::Type, ::Nothing, ::Nothing, name) = nothing
function check_type_and_multiple_names(
    ::Type{T},
    value::T,
    ::Nothing,
    name,
) where {T}
    return value
end
function check_type_and_multiple_names(::Type, ::Any, ::Nothing, name) where {T}
    return nothing
end
function check_type_and_multiple_names(
    ::Type{T},
    ::Nothing,
    value::T,
    name,
) where {T}
    return value
end
function check_type_and_multiple_names(::Type, ::Nothing, ::Any, name) where {T}
    return nothing
end
function check_type_and_multiple_names(T::Type, ::Any, ::Any, name)
    return throw_multiple_name_error(T, name)
end
function MOI.get(
    uf::UniversalFallback,
    ::Type{CI{F,S}},
    name::String,
) where {F,S}
    if uf.name_to_con === nothing
        uf.name_to_con = build_name_to_con_map(uf.con_to_name)
    end
    if MOI.supports_constraint(uf.model, F, S)
        ci = MOI.get(uf.model, CI{F,S}, name)
    else
        # There is no `F`-in-`S` constraint in `b.model`, `ci` is only queried
        # to check for duplicate names.
        ci = MOI.get(uf.model, CI, name)
    end
    ci_uf = get(uf.name_to_con, name, nothing)
    throw_if_multiple_with_name(ci_uf, name)
    return check_type_and_multiple_names(CI{F,S}, ci_uf, ci, name)
end
function MOI.get(uf::UniversalFallback, ::Type{CI}, name::String)
    if uf.name_to_con === nothing
        uf.name_to_con = build_name_to_con_map(uf.con_to_name)
    end
    ci_uf = get(uf.name_to_con, name, nothing)
    throw_if_multiple_with_name(ci_uf, name)
    return check_type_and_multiple_names(
        CI,
        ci_uf,
        MOI.get(uf.model, CI, name),
        name,
    )
end

_set(uf, attr::MOI.AbstractOptimizerAttribute, value) = uf.optattr[attr] = value
_set(uf, attr::MOI.AbstractModelAttribute, value) = uf.modattr[attr] = value
function _set(uf, attr::MOI.AbstractVariableAttribute, vi::VI, value)
    if !haskey(uf.varattr, attr)
        uf.varattr[attr] = Dict{VI,Any}()
    end
    return uf.varattr[attr][vi] = value
end
function _set(uf, attr::MOI.AbstractConstraintAttribute, ci::CI, value)
    if !haskey(uf.conattr, attr)
        uf.conattr[attr] = Dict{CI,Any}()
    end
    return uf.conattr[attr][ci] = value
end
function MOI.supports(
    ::UniversalFallback,
    ::Union{MOI.AbstractModelAttribute,MOI.AbstractOptimizerAttribute},
)
    return true
end
function MOI.set(
    uf::UniversalFallback,
    attr::Union{MOI.AbstractOptimizerAttribute,MOI.AbstractModelAttribute},
    value,
)
    if MOI.supports(uf.model, attr)
        return MOI.set(uf.model, attr, value)
    else
        return _set(uf, attr, value)
    end
end
function MOI.supports(
    ::UniversalFallback,
    ::Union{MOI.AbstractVariableAttribute,MOI.AbstractConstraintAttribute},
    ::Type{<:MOI.Index},
)
    return true
end
function MOI.set(
    uf::UniversalFallback,
    attr::MOI.AbstractVariableAttribute,
    idx::VI,
    value,
)
    if MOI.supports(uf.model, attr, typeof(idx))
        return MOI.set(uf.model, attr, idx, value)
    else
        return _set(uf, attr, idx, value)
    end
end
function MOI.set(
    uf::UniversalFallback,
    attr::MOI.AbstractConstraintAttribute,
    idx::CI{F,S},
    value,
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S) &&
       MOI.supports(uf.model, attr, CI{F,S})
        return MOI.set(uf.model, attr, idx, value)
    else
        return _set(uf, attr, idx, value)
    end
end

# Constraints
function MOI.supports_constraint(
    uf::UniversalFallback,
    ::Type{F},
    ::Type{S},
) where {F<:MOI.AbstractFunction,S<:MOI.AbstractSet}
    return true
end
function _new_constraint_index(
    uf,
    f::MOI.SingleVariable,
    s::MOI.AbstractScalarSet,
)
    return CI{MOI.SingleVariable,typeof(s)}(f.variable.value)
end
function _new_constraint_index(uf, f::MOI.AbstractFunction, s::MOI.AbstractSet)
    uf.nextconstraintid += 1
    return CI{typeof(f),typeof(s)}(uf.nextconstraintid)
end
function MOI.add_constraint(
    uf::UniversalFallback,
    f::MOI.AbstractFunction,
    s::MOI.AbstractSet,
)
    F = typeof(f)
    S = typeof(s)
    if MOI.supports_constraint(uf.model, F, S)
        return MOI.add_constraint(uf.model, f, s)
    else
        constraints =
            get!(uf.constraints, (F, S)) do
                return OrderedDict{
                    CI{F,S},
                    Tuple{F,S},
                }()
            end::OrderedDict{CI{F,S},Tuple{F,S}}
        ci = _new_constraint_index(uf, canonical(f), copy(s))
        constraints[ci] = (f, s)
        return ci
    end
end
function MOI.modify(
    uf::UniversalFallback,
    ci::CI{F,S},
    change::MOI.AbstractFunctionModification,
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.modify(uf.model, ci, change)
    else
        (f, s) = uf.constraints[(F, S)][ci]
        uf.constraints[(F, S)][ci] = (modify_function(f, change), s)
    end
end

function MOI.get(
    uf::UniversalFallback,
    attr::MOI.ConstraintFunction,
    ci::CI{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.get(uf.model, attr, ci)
    else
        MOI.throw_if_not_valid(uf, ci)
        uf.constraints[(F, S)][ci][1]
    end
end
function MOI.get(
    uf::UniversalFallback,
    attr::MOI.ConstraintSet,
    ci::CI{F,S},
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.get(uf.model, attr, ci)
    else
        MOI.throw_if_not_valid(uf, ci)
        uf.constraints[(F, S)][ci][2]
    end
end
function MOI.set(
    uf::UniversalFallback,
    ::MOI.ConstraintFunction,
    ci::CI{F,S},
    func::F,
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.set(uf.model, MOI.ConstraintFunction(), ci, func)
    else
        MOI.throw_if_not_valid(uf, ci)
        if F == MOI.SingleVariable
            throw(MOI.SettingSingleVariableFunctionNotAllowed())
        end
        (_, s) = uf.constraints[(F, S)][ci]
        uf.constraints[(F, S)][ci] = (func, s)
    end
end
function MOI.set(
    uf::UniversalFallback,
    ::MOI.ConstraintSet,
    ci::CI{F,S},
    set::S,
) where {F,S}
    if MOI.supports_constraint(uf.model, F, S)
        MOI.set(uf.model, MOI.ConstraintSet(), ci, set)
    else
        MOI.throw_if_not_valid(uf, ci)
        (f, _) = uf.constraints[(F, S)][ci]
        uf.constraints[(F, S)][ci] = (f, set)
    end
end

# Variables
MOI.add_variable(uf::UniversalFallback) = MOI.add_variable(uf.model)
MOI.add_variables(uf::UniversalFallback, n) = MOI.add_variables(uf.model, n)
