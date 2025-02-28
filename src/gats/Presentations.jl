""" Finite presentations of a model of a generalized algebraic theory (GAT).

We support two methods for defining models of a GAT: as Julia objects using the
`@instance` macro and as syntactic objects using the `@present` macro.
Instances are useful for casting generic data structures, such as matrices,
abstract tensor systems, and wiring diagrams, in categorical language.
Presentations define small categories by generators and relations and are useful
in applications like knowledge representation.
"""
module Presentations
export @present, Presentation, generator, generators, generator_index,
  has_generator, equations, add_generator!, add_generators!, add_definition!,
  add_equation!, add_equations!

using Base.Meta: ParseError
using MLStyle: @match

using ..MetaUtils, ..SyntaxSystems
import ..TheoriesInstances as GAT
import ..SyntaxSystems: parse_json_sexpr, to_json_sexpr

# Data types
############

struct Presentation{Theory,Name}
  syntax::Module
  generators::NamedTuple
  generator_name_index::Dict{Name,Pair{Symbol,Int}}
  equations::Vector{Pair}
end

function Presentation{Name}(syntax::Module) where Name
  Theory = syntax.theory()
  theory = GAT.theory(Theory)
  names = Tuple(type.name for type in theory.types)
  vectors = ((getfield(syntax, name){:generator})[] for name in names)
  Presentation{Theory,Name}(syntax, NamedTuple{names}(vectors),
                            Dict{Name,Pair{Symbol,Int}}(), Pair[])
end
Presentation(syntax::Module) = Presentation{Symbol}(syntax)

function Base.:(==)(pres1::Presentation, pres2::Presentation)
  pres1.syntax == pres2.syntax && pres1.generators == pres2.generators &&
    pres1.equations == pres2.equations
end

function Base.copy(pres::Presentation{T,Name}) where {T,Name}
  Presentation{T,Name}(pres.syntax, map(copy, pres.generators),
                       copy(pres.generator_name_index), copy(pres.equations))
end

# Presentation
##############

""" Get all generators of a presentation.
"""
generators(pres::Presentation) = collect(Iterators.flatten(pres.generators))
generators(pres::Presentation, type::Symbol) = pres.generators[type]
generators(pres::Presentation, type::Type) = generators(pres, nameof(type))

""" Retrieve generators by name.

Generators can also be retrieved using indexing notation, so that
`generator(pres, name)` and `pres[name]` are equivalent.
"""
function generator(pres::Presentation, name)
  type, index = pres.generator_name_index[name]
  pres.generators[type][index]
end
Base.getindex(pres::Presentation, name) = generator.(Ref(pres), name)

""" Does the presentation contain a generator with the given name?
"""
function has_generator(pres::Presentation, name)
  haskey(pres.generator_name_index, name)
end

""" Add a generator to a presentation.
"""
function add_generator!(pres::Presentation, expr)
  name, type = first(expr), gat_typeof(expr)
  generators = pres.generators[type]
  if !isnothing(name)
    if haskey(pres.generator_name_index, name)
      error("Name $name already defined in presentation")
    end
    pres.generator_name_index[name] = type => length(generators)+1
  end
  push!(generators, expr)
  expr
end

""" Add iterable of generators to a presentation.
"""
function add_generators!(pres::Presentation, exprs)
  for expr in exprs
    add_generator!(pres, expr)
  end
end

""" Get all equations of a presentation.
"""
equations(pres::Presentation) = pres.equations

""" Add an equation between terms to a presentation.
"""
add_equation!(pres::Presentation, lhs::GATExpr, rhs::GATExpr) =
  push!(pres.equations, lhs => rhs)

""" Add sequence of equations to a presentation.
"""
add_equations!(pres::Presentation, eqs) = append!(pres.equations, eqs)

""" Add a generator defined by an equation.
"""
function add_definition!(pres::Presentation, name::Symbol, rhs::GATExpr)
  generator = SyntaxSystems.generator_like(rhs, name)
  add_generator!(pres, generator)
  add_equation!(pres, generator, rhs)
  generator
end

""" Get the index of a generator, relative to generators of same GAT type.
"""
function generator_index(pres::Presentation{T,Name}, name::Name) where {T,Name}
  last(pres.generator_name_index[name])
end
function generator_index(pres::Presentation, expr::GATExpr{:generator})
  name = first(expr)
  !isnothing(name) || error("Cannot lookup unnamed generator by name")
  generator_index(pres, name)
end

""" Shorthand for contructing a term in the presentation
"""
function make_term(pres::Presentation, expr)
  @match expr begin
    ::Symbol => pres[expr]
    Expr(:call, term_constructor, args...) =>
      invoke_term(pres.syntax, term_constructor,
                  map(arg -> make_term(pres, arg), args)...)
  end
end

""" Create a new generator in a presentation of a given type
"""
function make_generator(pres::Presentation, name::Union{Symbol,Nothing},
                        type::Symbol, type_args::Vector)
  invoke_term(pres.syntax, type, name,
              map(e -> make_term(pres, e), type_args)...)
end

""" Create and add a new generator
"""
function construct_generator!(pres::Presentation, name::Union{Symbol,Nothing},
                              type::Symbol, type_args::Vector=[])
  add_generator!(pres, make_generator(pres, name, type, type_args))
end

""" Create and add multiple generators
"""
function construct_generators!(pres::Presentation, names::AbstractVector,
                               type::Symbol, type_args::Vector=[])
  for name in names
    construct_generator!(pres, name, type, type_args)
  end
end

# Presentation Definition
#########################

function add_to_presentation(pres, block)
  pres = copy(pres)
  @match strip_lines(block) begin
    Expr(:block, lines...) =>
      for line in lines
        eval_stmt!(pres, line)
      end
    _ => error("Must pass in a block")
  end
  pres
end

function parse_type_expr(type_expr)
  @match type_expr begin
    Expr(:call, f::Symbol, args...) => (f,[args...])
    f::Symbol => (f,[])
    _ => error("Ill-formed type expression $type_expr")
  end
end

function eval_stmt!(pres::Presentation, stmt::Expr)
  @match stmt begin
    Expr(:(::), name::Symbol, type_expr) =>
      construct_generator!(pres, name, parse_type_expr(type_expr)...)
    Expr(:(::), Expr(:tuple, names...), type_expr) =>
      construct_generators!(pres, [names...], parse_type_expr(type_expr)...)
    Expr(:(::), type_expr) =>
      construct_generator!(pres, nothing, parse_type_expr(type_expr)...)
    Expr(:(:=), name::Symbol, def_expr) =>
      add_definition!(pres, name, make_term(pres, def_expr))
    Expr(:call, :(==), lhs, rhs) =>
      add_equation!(pres, make_term(pres, lhs), make_term(pres, rhs))
  end
end

# Presentation macro
####################

""" Define a presentation using a convenient syntax.
"""
macro present(head, body)
  name, pres = @match head begin
    Expr(:call, name::Symbol, syntax_name::Symbol) =>
      (name, :($(GlobalRef(Presentations, :Presentation))($(esc(syntax_name)))))
    Expr(:(<:), name::Symbol, parent::Symbol) => (name,:(copy($(esc(parent)))))
    _ => throw(ParseError("Ill-formed presentation header $head"))
  end
  quote
    $(esc(name)) = $(esc(add_to_presentation))($pres, $(Expr(:quote, body)))
  end
end

# Serialization
###############

function to_json_sexpr(pres::Presentation, expr::GATExpr)
  to_json_sexpr(expr;
    by_reference = name -> has_generator(pres, name))
end

function parse_json_sexpr(pres::Presentation{Theory,Name},
                          syntax::Module, sexpr) where {Theory,Name}
  parse_json_sexpr(syntax, sexpr;
    symbols = Name == Symbol,
    parse_reference = name -> generator(pres, name))
end

end
