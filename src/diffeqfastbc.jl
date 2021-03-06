import Base.Broadcast: _broadcast_getindex, preprocess, preprocess_args, Broadcasted, broadcast_unalias, combine_axes, broadcast_axes, broadcast_shape, check_broadcast_axes, check_broadcast_shape, throwdm, broadcastable, AbstractArrayStyle, DefaultArrayStyle
import Base: copyto!, tail, axes, length, ndims
struct DiffEqBC{T}
    x::T
end
@inline axes(b::DiffEqBC) = axes(b.x)
@inline length(b::DiffEqBC) = length(b.x)
@inline broadcastable(b::DiffEqBC) = b
@inline Base.ndims(b::Type{DiffEqBC{T}}) where T = ndims(T)
Base.@propagate_inbounds _broadcast_getindex(b::DiffEqBC, i) = _broadcast_getindex(b.x, i)
Base.@propagate_inbounds _broadcast_getindex(b::DiffEqBC{<:AbstractArray{<:Any,0}}, i) = b.x[]
Base.@propagate_inbounds _broadcast_getindex(b::DiffEqBC{<:AbstractVector}, i) = b.x[i[1]]
Base.@propagate_inbounds _broadcast_getindex(b::DiffEqBC{<:AbstractArray}, i) = b.x[i]
diffeqbc(x::Array) = DiffEqBC(x)
diffeqbc(x::LabelledArrays.LArray) = DiffEqBC(x)
diffeqbc(x::Adjoint{<:Array}) = DiffEqBC(x)
diffeqbc(x::Transpose{<:Array}) = DiffEqBC(x)
diffeqbc(x::MArray) = DiffEqBC(x)
diffeqbc(x) = x

# Ensure inlining
@static if VERSION < v"1.5.0-DEV.634"
    @inline combine_axes(A, B) = broadcast_shape(broadcast_axes(A), broadcast_axes(B)) # Julia 1.0 compatible
end

@inline check_broadcast_axes(shp, A::Union{Number, Array, Broadcasted}) = check_broadcast_shape(shp, axes(A))

@noinline throwfastbc(axesA, axesB) = throw(DimensionMismatch("DiffEq's fast broadcast cannot broadcast $axesA with $axesB"))
@inline preprocess(f::typeof(diffeqbc), dest, bc::Broadcasted{Style}) where {Style} = Broadcasted{Style}(bc.f, preprocess_args(f, dest, bc.args), bc.axes)
@inline function preprocess(f::typeof(diffeqbc), dest, x)
    axesdest = axes(dest)
    axesx = axes(x)
    if !(axesdest === () || axesx === ())
        axesdest == axesx || throwfastbc(axesdest, axesx)
    end
    f(broadcast_unalias(dest, x))
end

@inline preprocess_args(f::typeof(diffeqbc), dest, args::Tuple) = (preprocess(f, dest, args[1]), preprocess_args(f, dest, tail(args))...)
@inline preprocess_args(f::typeof(diffeqbc), dest, args::Tuple{Any}) = (preprocess(f, dest, args[1]),)
preprocess_args(f::typeof(diffeqbc), dest, args::Tuple{}) = ()

# Performance optimization for the common identity scalar case: dest .= val
@inline copyto!(dest::DiffEqBC, bc::Broadcasted{<:AbstractArrayStyle{0}}) = copyto!(dest.x, bc)
for B in (Broadcasted, Broadcasted{<:StaticArrays.StaticArrayStyle}) # fix ambiguity
  @eval @inline function copyto!(dest::DiffEqBC, bc::$B)
      axes(dest) == axes(bc) || throwdm(axes(dest), axes(bc))
      dest′ = dest.x
      # Performance optimization: broadcast!(identity, dest, A) is equivalent to copyto!(dest, A) if indices match
      if bc.f === identity && bc.args isa Tuple{AbstractArray} # only a single input argument to broadcast!
          A = bc.args[1]
          if axes(dest) == axes(A)
              return copyto!(dest′, A)
          end
      end
      bcs′ = preprocess(diffeqbc, dest, bc)
      @simd ivdep for I in eachindex(bcs′)
          @inbounds dest′[I] = bcs′[I]
      end
      return dest′ # return the original array without the wrapper
  end
end

# Forcing `broadcasted` to inline is not necessary, since `Vern9` plays well
# with the Base implementation, and `Feagin`s do not use broadcasting.
#
#import Base.Broadcast: broadcasted, combine_styles
#map_nostop(f, t::Tuple{})              = ()
#map_nostop(f, t::Tuple{Any,})          = (f(t[1]),)
#map_nostop(f, t::Tuple{Any, Any})      = (f(t[1]), f(t[2]))
#map_nostop(f, t::Tuple{Any, Any, Any}) = (f(t[1]), f(t[2]), f(t[3]))
#map_nostop(f, t::Tuple)                = (Base.@_inline_meta; (f(t[1]), map_nostop(f,tail(t))...))
#@inline function broadcasted(f::Union{typeof(*), typeof(+), typeof(muladd)}, arg1, arg2, args...)
#    arg1′ = broadcastable(arg1)
#    arg2′ = broadcastable(arg2)
#    args′ = map_nostop(broadcastable, args)
#    broadcasted(combine_styles(arg1′, arg2′, args′...), f, arg1′, arg2′, args′...)
#end

macro ..(x)
    expr = Base.Broadcast.__dot__(x)
    if expr.head in (:(.=), :(.+=), :(.-=), :(.*=), :(./=), :(.\=), :(.^=)) # we exclude `÷=` `%=` `&=` `|=` `⊻=` `>>>=` `>>=` `<<=` because they are for integers
      name = gensym()
      dest = :(diffeqbc($(esc(expr.args[1]))))
      expr.args[1] = name
      return quote
        $(esc(name)) = $dest
        $(esc(expr))
      end
    else
      return esc(expr)
    end
end
