""" Syntax for a generalized algebraic theory (GAT).

Unlike instances of a theory, syntactic expressions don't necessarily satisfy
the equations of the theory. For example, the default syntax operations for the
`Category` theory don't form a category because they don't satisfy the category
laws, e.g.,
```
compose(f, id(A)) != compose(f)
```
Whether dependent types are enforced at runtime and whether expressions are
automatically brought to normal form depends on the particular syntax. In
general, a single theory may have many different syntaxes. The purpose of this
module to make the construction of syntax simple but flexible.
"""
module Syntax
export @syntax, BaseExpr, SyntaxDomainError, head, args, first, last,
  associate, associate_unit, 
  show_sexpr, show_unicode, show_unicode_infix, show_latex, show_latex_infix

import Base: first, last, show, showerror, ==
import Base.Meta: show_sexpr
using Match

import ..GAT
import ..GAT: Context, Signature, TypeConstructor, TermConstructor,
  JuliaFunction

# Data types
############

""" Base type for expression in the syntax of a GAT.

We define Julia types for each *type constructor* in the theory, e.g., object,
morphism*, and 2-morphism in the theory of 2-categories. Of course, Julia's
type system does not support dependent types, so the type parameters are
incorporated in the Julia types. (They are stored as extra data in the
expression instances.)
  
The concrete types are structurally similar to the core type `Expr` in Julia.
However, the *term constructor* is represented as a type parameter, rather than
as a `head` field. This makes dispatch using Julia's type system more
convenient.
"""
abstract BaseExpr{T}

term{T}(::Type{BaseExpr{T}}) = T
head{T}(::BaseExpr{T}) = T

args(expr::BaseExpr) = expr.args
first(expr::BaseExpr) = first(args(expr))
last(expr::BaseExpr) = last(args(expr))
type_args(expr::BaseExpr) = expr.type_args

function ==(e1::BaseExpr, e2::BaseExpr)
  head(e1) == head(e2) && args(e1) == args(e2) && type_args(e1) == type_args(e2)
end

function show(io::IO, expr::BaseExpr)
  print(io, head(expr))
  print(io, "(")
  join(io, args(expr), ",")
  print(io, ")")
end
show(io::IO, expr::BaseExpr{:generator}) = print(io, first(expr))

type SyntaxDomainError <: Exception
  constructor::Symbol
  args::Vector
end

function showerror(io::IO, exc::DomainError)
  print(io, "Domain error in term constructor $(exc.constructor)(")
  join(io, exc.args, ",")
  print(io, ")")
end

# Syntax
########

""" TODO
"""
macro syntax(syntax_head, mod_name, body=Expr(:block))
  @assert body.head == :block
  syntax_name, base_types = @match syntax_head begin
    Expr(:call, [name::Symbol, args...], _) => (name, args)
    name::Symbol => (name, [])
    _ => throw(ParseError("Ill-formed syntax signature $syntax_head"))
  end
  functions = map(GAT.parse_function, GAT.strip_lines(body).args)
  
  expr = Expr(:call, :syntax_code, Expr(:quote, syntax_name),
              esc(Expr(:ref, :Type, base_types...)), esc(mod_name), functions)
  Expr(:block,
    Expr(:call, esc(:eval), expr),
    :(Core.@__doc__ $(esc(syntax_name))))
end
function syntax_code(name::Symbol, base_types::Vector{Type}, mod::Module,
                     functions::Vector)
  class = mod.class()
  signature = class.signature
  
  # Generate module with syntax types and type/term generators.
  mod = Expr(:module, true, name,
    Expr(:block, [
      Expr(:export, [cons.name for cons in signature.types]...);  
      gen_types(signature, base_types);
      gen_type_accessors(signature);
      gen_term_generators(signature);
      gen_term_constructors(signature);
    ]...))
  
  # Generate toplevel functions.
  toplevel = []
  bindings = Dict{Symbol,Any}(
    c.name => Expr(:(.), name, QuoteNode(c.name)) for c in signature.types)
  bindings[:Super] = name
  syntax_fns = Dict(GAT.parse_function_sig(f) => f for f in functions)
  for f in GAT.interface(class)
    sig = GAT.parse_function_sig(f)
    if haskey(syntax_fns, sig)
      # Case 1: The method is overriden in the syntax body.
      expr = GAT.gen_function(GAT.replace_symbols(bindings, syntax_fns[sig]))
    elseif !isnull(f.impl)
      # Case 2: The method is already implemented in signature.
      expr = GAT.gen_function(GAT.replace_symbols(bindings, f))
    else
      # Case 3: Call the default syntax method.
      params = [ gensym("x$i") for i in eachindex(sig.types) ]
      call_expr = Expr(:call, sig.name, 
        [ Expr(:(::), p, t) for (p,t) in zip(params, sig.types) ]...)
      body = Expr(:call, Expr(:(.), name, QuoteNode(sig.name)), params...)
      f_impl = JuliaFunction(call_expr, f.return_type, body)
      # Inline these very short functions.
      expr = Expr(:macrocall, Symbol("@inline"),
                  GAT.gen_function(GAT.replace_symbols(bindings, f_impl)))
    end
    push!(toplevel, expr)
  end
  Expr(:toplevel, mod, toplevel...)
end

""" Generate syntax type definitions.
"""
function gen_type(cons::TypeConstructor, base_type::Type=Any)::Expr
  base_expr = GlobalRef(Syntax, :BaseExpr)
  base_name = if base_type == Any
    base_expr
  else
    GlobalRef(base_type.name.module, base_type.name.name)
  end
  expr = :(immutable $(cons.name){T} <: $base_name{T}
    args::Vector
    type_args::Vector{$base_expr}
  end)
  GAT.strip_lines(expr, recurse=true)
end
function gen_types(sig::Signature, base_types::Vector{Type})::Vector{Expr}
  if isempty(base_types)
    map(gen_type, sig.types)
  else
    map(gen_type, sig.types, base_types)
  end
end

""" Generate accessor methods for type parameters.
"""
function gen_type_accessors(cons::TypeConstructor)::Vector{Expr}
  fns = []
  sym = gensym(:x)
  for (i, param) in enumerate(cons.params)
    call_expr = Expr(:call, param, Expr(:(::), sym, cons.name))
    return_type = GAT.strip_type(cons.context[param])
    body = Expr(:ref, Expr(:(.), sym, QuoteNode(:type_args)), i)
    push!(fns, GAT.gen_function(JuliaFunction(call_expr, return_type, body)))
  end
  fns
end
function gen_type_accessors(sig::Signature)::Vector{Expr}
  vcat(map(gen_type_accessors, sig.types)...)
end

""" Generate methods for syntax term constructors.
"""
function gen_term_constructor(cons::TermConstructor, sig::Signature)::Expr
  head = GAT.constructor(cons)
  call_expr, return_type = head.call_expr, get(head.return_type)
  body = Expr(:block)
  
  # Create expression to check constructor domain.
  eqs = GAT.equations(cons, sig)
  if !isempty(eqs)
    clauses = [ Expr(:call,:(==),lhs,rhs) for (lhs,rhs) in eqs ]
    conj = foldr((x,y) -> Expr(:(&&),x,y), clauses)
    insert!(call_expr.args, 2,
      Expr(:parameters, Expr(:kw, :strict, false)))
    push!(body.args,
      Expr(:if,
        Expr(:(&&), :strict, Expr(:call, :(!), conj)),
        Expr(:call, :throw,
          Expr(:call, GlobalRef(Syntax, :SyntaxDomainError),
            Expr(:quote, cons.name),
            Expr(:vect, cons.params...)))))
  end
  
  # Create call to expression constructor.
  return_expr = gen_term_constructor_expr(cons, sig)
  type_params = @match return_expr begin
    Expr(:call, [name::Symbol, args...], _) => args
    _::Symbol => []
  end
  push!(body.args,
    Expr(:call,
      Expr(:curly, return_type, Expr(:quote, cons.name)),
      Expr(:vect, cons.params...),
      Expr(:vect, type_params...)))
  
  GAT.gen_function(JuliaFunction(call_expr, return_type, body))
end
function gen_term_constructors(sig::Signature)::Vector{Expr}
  [ gen_term_constructor(cons, sig) for cons in sig.terms ]
end

""" Generate expression for return type of term constructor.

Besides expanding the implicit variables, we must handle two annoying issues:
1. Replace nullary constructors with unary constructors per our convention, e.g.
   munit() -> munit(Ob)
2. Rebind the term constructors to ensure that user overrides are preferred over
   the default term constructors.
"""
function gen_term_constructor_expr(cons, sig)
  expr = GAT.expand_term_type(cons, sig)
  expr = replace_nullary_constructors(expr, sig)
  
  # XXX: Is there another way? Fetching the current module seems like a hack.
  mod = current_module()
  bindings = Dict(c.name => GlobalRef(mod, c.name) for c in sig.terms)
  GAT.replace_symbols(bindings, expr)
end
function replace_nullary_constructors(expr, sig)
  @match expr begin
    Expr(:call, [name::Symbol], _) => begin
      terms = sig.terms[find(cons -> cons.name == name, sig.terms)]
      @assert length(terms) == 1
      Expr(:call, name, terms[1].typ)
    end
    Expr(:call, [name::Symbol, args...], _) =>
      Expr(:call, name, [replace_nullary_constructors(a,sig) for a in args]...)
    _ => expr
  end
end

""" Generate methods for term generators.

Effectively, these generators are arity-zero term constructors that we allow to
be created on the fly.
"""
function gen_term_generator(cons::TypeConstructor)::Expr
  name = Symbol(lowercase(string(cons.name)))
  @assert name != cons.name # XXX: We are enforcing a case convention...
  name_param = gensym(:sym)
  type_params = [ Expr(:(::), p, GAT.strip_type(cons.context[p]))
                  for p in cons.params ]
  call_expr = Expr(:call, name, :($name_param::Symbol), type_params...)
  body = Expr(:call,
    Expr(:curly, cons.name, QuoteNode(:generator)),
    Expr(:vect, name_param),
    Expr(:vect, cons.params...),
  )
  GAT.gen_function(JuliaFunction(call_expr, cons.name, body))
end
function gen_term_generators(sig::Signature)::Vector{Expr}
  map(gen_term_generator, sig.types)
end

# Normal forms
##############

""" Apply associative binary operation.

Maintains the normal form `op(e1,e2,...)` where `e1`,`e2`,... are expressions
that are *not* applications of `op()`
"""
function associate{E<:BaseExpr}(expr::E)::E
  op, e1, e2 = head(expr), first(expr), last(expr)
  args1 = head(e1) == op ? args(e1) : [e1]
  args2 = head(e2) == op ? args(e2) : [e2]
  E([args1; args2], type_args(expr))
end

""" Apply associative binary operation with unit.

Reduces a freely generated (typed) monoid to normal form.
"""
function associate_unit(unit::Symbol, expr::BaseExpr)::BaseExpr
  e1, e2 = first(expr), last(expr)
  if (head(e1) == unit) e2
  elseif (head(e2) == unit) e1
  else associate(expr) end
end

# Pretty-print
##############

""" Show the syntax expression as an S-expression.

The transformation is *not* one-to-one since type arguments (e.g. domains and
codomains of morphisms) are not shown.

Cf. the standard library function `Meta.show_sexpr`.
"""
show_sexpr(expr::BaseExpr) = show_sexpr(STDOUT, expr)
show_sexpr(io::IO, expr::BaseExpr) = print(io, as_sexpr(expr))

function as_sexpr(expr::BaseExpr)::String
  if head(expr) == :generator
    repr(first(expr))
  else
    string("(", join([head(expr), map(as_sexpr,args(expr))...], " "), ")")
  end
end

""" Show the expression in infix notation using Unicode symbols.
"""
show_unicode(expr::BaseExpr) = show_unicode(STDOUT, expr)

# By default, show in prefix notation.
function show_unicode(io::IO, expr::BaseExpr; kw...)
  print(io, head(expr))
  print(io, "[")
  join(io, [sprint(show_unicode, arg) for arg in args(expr)], ",")
  print(io, "]")
end
show_unicode(io::IO, expr::BaseExpr{:generator}; kw...) = print(io, first(expr))

function show_unicode_infix(io::IO, expr::BaseExpr, op::String; paren::Bool=false)
  show_unicode_paren(io::IO, expr::BaseExpr) = show_unicode(io, expr; paren=true)
  if (paren) print(io, "(") end
  join(io, [sprint(show_unicode_paren, arg) for arg in args(expr)], op)
  if (paren) print(io, ")") end
end

""" Show the expression in infix notation using LaTeX math.

Does *not* include `\$` or `\\[begin|end]{equation}` delimiters.
"""
show_latex(expr::BaseExpr) = show_latex(STDOUT, expr)

# By default, show in prefix notation.
function show_latex(io::IO, expr::BaseExpr; kw...)
  print(io, "\\mathrm{$(head(expr))}")
  print(io, "\\left[")
  join(io, [sprint(show_latex, arg) for arg in args(expr)], ",")
  print(io, "\\right]")
end
show_latex(io::IO, expr::BaseExpr{:generator}; kw...) = print(io, first(expr))

function show_latex_infix(io::IO, expr::BaseExpr, op::String; paren::Bool=false, kw...)
  show_latex_paren(io::IO, expr::BaseExpr) = show_latex(io, expr; paren=true, kw...)
  sep = op == " " ? op : " $op "
  if (paren) print(io, "\\left(") end
  join(io, [sprint(show_latex_paren, arg) for arg in args(expr)], sep)
  if (paren) print(io, "\\right)") end
end

function show(io::IO, ::MIME"text/latex", expr::BaseExpr)
  print(io, "\$")
  show_latex(io, expr)
  print(io, "\$")
end

# # Monoidal category
# as_latex(::ObExpr, ::Type{Val{:unit}}; kw...) = "I"
# function as_latex(expr::BaseExpr, ::Type{Val{:otimes}}; paren::Bool=false, kw...)
#   binary_op(expr, "\\otimes", paren)
# end
# 
# # Symmetric monoidal category
# function as_latex(expr::MorExpr, ::Type{Val{:braid}}; kw...)
#   subscript("\\sigma", join(map(as_latex, args(expr)), ","))
# end
# 
# # Internal (co)monoid
# function as_latex(expr::MorExpr, ::Type{Val{:copy}}; kw...)
#   subscript("\\Delta", as_latex(dom(expr)))
# end
# function as_latex(expr::MorExpr, ::Type{Val{:delete}}; kw...)
#   subscript("e", as_latex(dom(expr)))
# end
# function as_latex(expr::MorExpr, ::Type{Val{:merge}}; kw...)
#   subscript("\\nabla", as_latex(codom(expr)))
# end
# function as_latex(expr::MorExpr, ::Type{Val{:create}}; kw...)
#   subscript("i", as_latex(codom(expr)))
# end
# 
# # Closed compact category
# function as_latex(expr::ObExpr, ::Type{Val{:dual}}; kw...)
#   supscript(as_latex(first(args(expr))), "*")
# end
# function as_latex(expr::MorExpr, ::Type{Val{:eval}}; kw...)
#   subscript("\\mathrm{ev}", as_latex(first(args(expr))))
# end
# function as_latex(expr::MorExpr, ::Type{Val{:coeval}}; kw...)
#   subscript("\\mathrm{coev}", as_latex(first(args(expr))))
# end
# 
# # Dagger category
# function as_latex(expr::MorExpr, ::Type{Val{:dagger}}; kw...)
#   f = first(args(expr))
#   result = as_latex(f)
#   supscript(head(f) == :gen ? result : "\\left($result\\right)", "\\dagger")
# end

end
