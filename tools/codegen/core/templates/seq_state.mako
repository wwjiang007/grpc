// Copyright 2025 gRPC authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#ifndef GRPC_SRC_CORE_LIB_PROMISE_DETAIL_SEQ_STATE_H
#define GRPC_SRC_CORE_LIB_PROMISE_DETAIL_SEQ_STATE_H

// This file is generated by tools/codegen/core/gen_seq.py

#include <grpc/support/port_platform.h>

#include <stdint.h>

#include <utility>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "absl/base/attributes.h"
#include "absl/strings/str_cat.h"

#include "src/core/lib/debug/trace.h"
#include "src/core/util/construct_destruct.h"
#include "src/core/util/debug_location.h"
#include "src/core/lib/promise/detail/promise_factory.h"
#include "src/core/lib/promise/detail/promise_like.h"
#include "src/core/lib/promise/promise.h"
#include "src/core/lib/promise/poll.h"
#include "src/core/lib/promise/map.h"

// A sequence under some traits for some set of callables P, Fs.
// P should be a promise-like object that yields a value.
// Fs... should be promise-factory-like objects that take the value from the
// previous step and yield a promise. Note that most of the machinery in
// PromiseFactory exists to make it possible for those promise-factory-like
// objects to be anything that's convenient.
// Traits defines how we move from one step to the next. Traits sets up the
// wrapping and escape handling for the sequence.
// Promises return wrapped values that the trait can inspect and unwrap before
// passing them to the next element of the sequence. The trait can
// also interpret a wrapped value as an escape value, which terminates
// evaluation of the sequence immediately yielding a result. Traits for type T
// have the members:
//  * type UnwrappedType - the type after removing wrapping from T (i.e. for
//    TrySeq, T=StatusOr<U> yields UnwrappedType=U).
//  * type WrappedType - the type after adding wrapping if it doesn't already
//    exist (i.e. for TrySeq if T is not Status/StatusOr/void, then
//    WrappedType=StatusOr<T>; if T is Status then WrappedType=Status (it's
//    already wrapped!))
//  * template <typename Next> void CallFactory(Next* next_factory, T&& value) -
//    call promise factory next_factory with the result of unwrapping value, and
//    return the resulting promise.
//  * template <typename Result, typename RunNext> Poll<Result>
//    CheckResultAndRunNext(T prior, RunNext run_next) - examine the value of
//    prior, and decide to escape or continue. If escaping, return the final
//    sequence value of type Poll<Result>. If continuing, return the value of
//    run_next(std::move(prior)).
//
// A state contains the current promise, and the promise factory to turn the
// result of the current promise into the next state's promise. We play a shell
// game such that the prior state and our current promise are kept in a union,
// and the next promise factory is kept alongside in the state struct.
// Recursively this guarantees that the next functions get initialized once, and
// destroyed once, and don't need to be moved around in between, which avoids a
// potential O(n**2) loop of next factory moves had we used a variant of states
// here. The very first state does not have a prior state, and so that state has
// a partial specialization below. The final state does not have a next state;
// that state is inlined in BasicSeq since that was simpler to type.
//
// The final state machine is built only after a simplification pass over the
// sequence. This pass examines the sequence and leverages subsequences that
// are known to be instantaneous to avoid the overhead of the state machine.
// How do we know something is instantaneous? If the promise factory returns
// something other than a promise that returns Poll<> then we know we can
// evaluate it immediately.
//
// Simplification proceeds in four phases:
//
// Phase 1: Labelling, inside Simplify()
//   Here we construct a bitfield that tells us which steps are instantaneous
//   and which ones are not. This allows us to leverage constexpr if over the
//   bitfield to speed up compilation and simplify the logic herein.
//   The bitfield is constructed such that the 0 bit corresponds to the last
//   factory in the sequence, and the n-1 bit corresponds to the first factory.
//   This is a bit confusing when doing the shifts and masks, but ensures that
//   the bit pattern that shows up in the generated text is in the same order
//   as the promise factories in the argument lists to Simplify() and friends,
//   which greatly aids in debugging.
// Phase 2: Right Simplification, inside SimplifyRight():
//   Here we take advantage of the identity Seq(A, I) == Map(A, I) for a
//   promise A and an instantanious promise factory I. We examine the last
//   bits of the bitfield and merge together all trailing instantaneous steps
//   into a single map.
// Phase 3: Left Simplification, inside SimplifyLeft():
//   Leveraging the same identity, we now look to the first bits of the
//   bitfield, and merge any instantaneous steps into the first promise.
// Phase 4: Middle Simplification, inside SimplifyMiddle():
//   Here we look at the remaining steps in the bitfield and merge sequences
//   of instantaneous steps into a single map.

<%def name="constexpr_if(first, cond)">
${"if" if first else "else if"} constexpr (${cond})
</%def>

namespace grpc_core {
namespace promise_detail {
template <template<typename> class Traits, typename P, typename... Fs>
struct SeqState;
template <template<typename> class Traits, typename P, typename... Fs>
struct SeqStateTypes;
template <template<typename> class Traits, typename P>
struct SeqStateTypes<Traits, P> {
  using LastPromiseResult = typename Traits<typename PromiseLike<P>::Result>::UnwrappedType;
};

<%def name="decl(promise_name, i, n)">
using Promise${i} = ${promise_name};
% if i < n-1:
using NextFactory${i} = OncePromiseFactory<typename Promise${i}::Result, F${i}>;
${decl(f"typename NextFactory{i}::Promise", i+1, n)}
% endif
</%def>

///////////////////////////////////////////////////////////////////////////////
// SeqStateTypes
//

% for n in range(2, max_steps):
template <template<typename> class Traits, typename P, ${",".join(f"typename F{i}" for i in range(0,n-1))}>
struct SeqStateTypes<Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}> {
<% name="PromiseLike<P>" %>
% for i in range(0,n-1):
using Promise${i} = ${name};
using PromiseResult${i} = typename Promise${i}::Result;
using PromiseResultTraits${i} = Traits<PromiseResult${i}>;
using NextFactory${i} = OncePromiseFactory<typename PromiseResultTraits${i}::UnwrappedType, F${i}>;
<% name=f"typename NextFactory{i}::Promise" %>
% endfor
using Promise${n-1} = ${name};
using PromiseResult${n-1} = typename Promise${n-1}::Result;
using PromiseResultTraits${n-1} = Traits<PromiseResult${n-1}>;
using Result = typename PromiseResultTraits${n-1}::WrappedType;
using LastPromiseResult = typename PromiseResultTraits${n-1}::UnwrappedType;
};
%endfor

///////////////////////////////////////////////////////////////////////////////
// SeqState
//

<%def name="state(i, n)">
% if i == 0:
Promise0 current_promise;
NextFactory0 next_factory;
% elif i == n-1:
union {
    struct { ${state(i-1, n)} } prior;
    Promise${i} current_promise;
};
% else:
union {
    struct { ${state(i-1, n)} } prior;
    P${i} current_promise;
};
NextFactory${i} next_factory;
% endif
</%def>

% for n in range(2, max_steps):
template <template<typename> class Traits, typename P, ${",".join(f"typename F{i}" for i in range(0,n-1))}>
struct SeqState<Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}> {
using Types = SeqStateTypes<Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}>;
% for i in range(0,n):
using Promise${i} = typename Types::Promise${i};
using PromiseResult${i} = typename Types::PromiseResult${i};
using PromiseResultTraits${i} = typename Types::PromiseResultTraits${i};
% endfor
% for i in range(0,n-1):
using NextFactory${i} = typename Types::NextFactory${i};
% endfor
using Result = typename Types::Result;
% if n == 1:
Promise0 current_promise;
% else:
%  for i in range(0,n-1):
struct Running${i} {
%   if i != 0:
union {
  GPR_NO_UNIQUE_ADDRESS Running${i-1} prior;
%   endif
  GPR_NO_UNIQUE_ADDRESS Promise${i} current_promise;
%   if i != 0:
};
%   endif
GPR_NO_UNIQUE_ADDRESS NextFactory${i} next_factory;
};
%  endfor
union {
    GPR_NO_UNIQUE_ADDRESS Running${n-2} prior;
    GPR_NO_UNIQUE_ADDRESS Promise${n-1} current_promise;
};
% endif
  enum class State : uint8_t { ${",".join(f"kState{i}" for i in range(0,n))} };
  GPR_NO_UNIQUE_ADDRESS State state = State::kState0;
  GPR_NO_UNIQUE_ADDRESS DebugLocation whence;

  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION SeqState(P&& p,
           ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))},
           DebugLocation whence) noexcept: whence(whence)  {
    Construct(&${"prior."*(n-1)}current_promise, std::forward<P>(p));
% for i in range(0,n-1):
    Construct(&${"prior."*(n-1-i)}next_factory, std::forward<F${i}>(f${i}));
% endfor
  }
  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION ~SeqState() {
    switch (state) {
% for i in range(0,n-1):
     case State::kState${i}:
      Destruct(&${"prior."*(n-1-i)}current_promise);
      goto tail${i};
% endfor
     case State::kState${n-1}:
      Destruct(&current_promise);
      return;
    }
% for i in range(0,n-1):
tail${i}:
    Destruct(&${"prior."*(n-1-i)}next_factory);
% endfor
  }
  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION SeqState(const SeqState& other) noexcept : state(other.state), whence(other.whence) {
    DCHECK(state == State::kState0);
    Construct(&${"prior."*(n-1)}current_promise,
            other.${"prior."*(n-1)}current_promise);
% for i in range(0,n-1):
    Construct(&${"prior."*(n-1-i)}next_factory,
              other.${"prior."*(n-1-i)}next_factory);
% endfor
  }
  SeqState& operator=(const SeqState& other) = delete;
  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION SeqState(SeqState&& other) noexcept : state(other.state), whence(other.whence) {
    DCHECK(state == State::kState0);
    Construct(&${"prior."*(n-1)}current_promise,
              std::move(other.${"prior."*(n-1)}current_promise));
% for i in range(0,n-1):
    Construct(&${"prior."*(n-1-i)}next_factory,
              std::move(other.${"prior."*(n-1-i)}next_factory));
% endfor
  }
  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION SeqState& operator=(SeqState&& other) = delete;
  GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION Poll<Result> operator()() {
    switch (state) {
% for i in range(0,n-1):
      case State::kState${i}: {
        GRPC_TRACE_LOG(promise_primitives, INFO).AtLocation(whence.file(), whence.line())
                << "seq[" << this << "]: begin poll step ${i+1}/${n}";
        auto result = ${"prior."*(n-1-i)}current_promise();
        PromiseResult${i}* p = result.value_if_ready();
        GRPC_TRACE_LOG(promise_primitives, INFO).AtLocation(whence.file(), whence.line())
                << "seq[" << this << "]: poll step ${i+1}/${n} gets "
                << (p != nullptr
                    ? (PromiseResultTraits${i}::IsOk(*p)
                      ? "ready"
                      : absl::StrCat("early-error:", PromiseResultTraits${i}::ErrorString(*p)).c_str())
                    : "pending");
        if (p == nullptr) return Pending{};
        if (!PromiseResultTraits${i}::IsOk(*p)) {
          return PromiseResultTraits${i}::template ReturnValue<Result>(std::move(*p));
        }
        Destruct(&${"prior."*(n-1-i)}current_promise);
        auto next_promise = PromiseResultTraits${i}::CallFactory(&${"prior."*(n-1-i)}next_factory, std::move(*p));
        Destruct(&${"prior."*(n-1-i)}next_factory);
        Construct(&${"prior."*(n-2-i)}current_promise, std::move(next_promise));
        state = State::kState${i+1};
      }
      [[fallthrough]];
% endfor
      default:
      case State::kState${n-1}: {
        GRPC_TRACE_LOG(promise_primitives, INFO).AtLocation(whence.file(), whence.line())
                << "seq[" << this << "]: begin poll step ${n}/${n}";
        auto result = current_promise();
        GRPC_TRACE_LOG(promise_primitives, INFO).AtLocation(whence.file(), whence.line())
                << "seq[" << this << "]: poll step ${n}/${n} gets "
                << (result.ready()? "ready" : "pending");
        auto* p = result.value_if_ready();
        if (p == nullptr) return Pending{};
        return Result(std::move(*p));
      }
    }
  }
};
%endfor

///////////////////////////////////////////////////////////////////////////////
// SeqMap
//

% for n in range(2, max_steps):
template <template<typename> class Traits, typename P, ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SeqMap(P&& p, ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))}) {
    using Types = SeqStateTypes<Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}>;
    return Map(
        std::forward<P>(p),
        [${",".join(f"f{i} = typename Types::NextFactory{i}(std::forward<F{i}>(f{i}))" for i in range(0,n-1))}]
        (typename Types::PromiseResult0 r0) mutable {
% for i in range(0, n-2):
            if (!Types::PromiseResultTraits${i}::IsOk(r${i})) {
                return Types::PromiseResultTraits${i}::template ReturnValue<typename Types::Result>(std::move(r${i}));
            }
            typename Types::PromiseResult${i+1} r${i+1} =
                Types::PromiseResultTraits${i}::CallFactoryThenPromise(&f${i}, std::move(r${i}));
% endfor
            if (!Types::PromiseResultTraits${n-2}::IsOk(r${n-2})) {
                return Types::PromiseResultTraits${n-2}::template ReturnValue<typename Types::Result>(std::move(r${n-2}));
            }
            return typename Types::Result(Types::PromiseResultTraits${n-2}::CallFactoryThenPromise(&f${n-2}, std::move(r${n-2})));
        }
    );
}
%endfor


///////////////////////////////////////////////////////////////////////////////
// SeqFactoryMap
//

template <template <typename> class Traits, typename Arg, typename F0>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SeqFactoryMap(F0&& f0) {
  if constexpr (!std::is_same_v<Arg, void>) {
    return [f0 = std::forward<F0>(f0)](Arg x) mutable {
      OncePromiseFactory<decltype(x), F0> next(std::move(f0));
      return next.Make(std::move(x));
    };
  } else {
    return [f0 = std::forward<F0>(f0)]() mutable {
      OncePromiseFactory<void, F0> next(std::move(f0));
      return next.Make();
    };
  }
}

% for n in range(3, max_steps):
template <template<typename> class Traits, typename Arg, ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SeqFactoryMap(${",".join(f"F{i}&& f{i}" for i in range(0,n-1))}) {
  if constexpr (!std::is_same_v<Arg, void>) {
    return [${",".join(f"f{i} = std::forward<F{i}>(f{i})" for i in range(0,n-1))}](Arg x) mutable {
      OncePromiseFactory<decltype(x), F0> next(std::move(f0));
      return SeqMap<Traits>(next.Make(std::move(x)), ${",".join(f"std::move(f{i})" for i in range(1,n-1))});
    };
  } else {
    return [${",".join(f"f{i} = std::forward<F{i}>(f{i})" for i in range(0,n-1))}]() mutable {
      OncePromiseFactory<void, F0> next(std::move(f0));
      return SeqMap<Traits>(next.Make(), ${",".join(f"std::move(f{i})" for i in range(1,n-1))});
    };
  }
}
%endfor

///////////////////////////////////////////////////////////////////////////////
// SimplifyMiddle

template <
    template <typename> class Traits, typename P, typename... Fs, size_t... Is>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto FinalizeSimplification(
    P&& p, std::tuple<Fs&&...>&& resolved,
    std::index_sequence<Is...>, DebugLocation whence) {
  return SeqState<Traits, P, Fs...>(std::forward<P>(p), std::forward<Fs>(std::get<Is>(resolved))..., whence);
}

template <template <typename> class Traits, uint32_t kInstantBits, typename P,
          typename... Fs>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SimplifyMiddle(
    P&& p, std::tuple<Fs&&...>&& resolved, DebugLocation whence) {
  static_assert(kInstantBits == 0);
  return FinalizeSimplification<Traits>(
      std::forward<P>(p), std::forward<std::tuple<Fs&&...>>(resolved),
      std::make_index_sequence<sizeof...(Fs)>(), whence);
}

% for n in range(2, max_steps):
template <
    template<typename> class Traits,
    uint32_t kInstantBits,
    typename P,
    typename... Rs,
    ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SimplifyMiddle(
    P&& p, std::tuple<Rs&&...>&& resolved, ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))},
    DebugLocation whence) {
  static_assert((kInstantBits & ${bin(1<<(n-2))}) == 0);
% for i in range(n-2, 0, -1):
  <%
  mask = ((1 << i) - 1) << (n - 2 - i)
  not_mask = (1 << (n - 2)) - 1 - mask
  first = i == n-2
  map = f"SeqFactoryMap<Traits, Arg>({','.join(f'std::forward<F{j}>(f{j})' for j in range(i+1))})"
  rest = [f"std::forward<F{j}>(f{j})" for j in range(i+1, n-1)] + ["whence"]
  %>
  ${constexpr_if(first, f"(kInstantBits & {bin(mask)}) == {bin(mask)}")} {
    using Arg = typename SeqStateTypes<Traits, P, Rs...>::LastPromiseResult;
    using MapType = decltype(${map});
    using FullTypesWithMap = SeqStateTypes<Traits, P, Rs..., MapType>;
    using FullTypesNoSimplification =
        SeqStateTypes<Traits, P, Rs..., ${','.join(f"F{j}" for j in range(i+1))}>;
    static_assert(std::is_same_v<
        typename FullTypesWithMap::LastPromiseResult,
        typename FullTypesNoSimplification::LastPromiseResult>);
    static_assert(std::is_same_v<
        typename FullTypesWithMap::Result,
        typename FullTypesNoSimplification::Result>);
    return SimplifyMiddle<Traits, (kInstantBits & ${bin(not_mask)})>(
        std::forward<P>(p),
        std::tuple_cat(
            std::forward<std::tuple<Rs&&...>>(resolved),
            std::tuple<MapType&&>(${map})),
            ${','.join(rest)});
  }
% endfor
% if n > 2:
  else {
% endif
  return SimplifyMiddle<Traits, 0>(
      std::forward<P>(p),
      std::tuple_cat(
          std::forward<std::tuple<Rs&&...>>(resolved),
          std::tuple<${','.join(f"F{i}&&" for i in range(0, n-1))}>(
              ${",".join(f"std::forward<F{i}>(f{i})" for i in range(0, n-1))})),
      whence);
% if n > 2:
  }
%endif
}
%endfor

///////////////////////////////////////////////////////////////////////////////
// SimplifyLeft

% for n in range(2, max_steps):
template <
    template<typename> class Traits,
    uint32_t kInstantBits,
    typename P,
    ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SimplifyLeft(
    P&& p, ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))},
    DebugLocation whence) {
  using Types = SeqStateTypes<
      Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}>;
% for i in range(n-1, 0, -1):
  <%
  mask = ((1 << i) - 1) << (n - 1 - i)
  not_mask = (1 << (n - 1)) - 1 - mask
  first = i == n-1
  map = f"SeqMap<Traits>(std::forward<P>(p), {','.join(f'std::forward<F{j}>(f{j})' for j in range(i))})"
  if not_mask:
    rest = [f'std::forward<F{j}>(f{j})' for j in range(i, n-1)] + ["whence"]
  else:
    rest = ["whence"]
  %>
  ${constexpr_if(first, f"(kInstantBits & {bin(mask)}) == {bin(mask)}")} {
    static_assert(std::is_same_v<
        typename PromiseLike<decltype(${map})>::Result,
        typename SeqStateTypes<
            Traits, P, ${','.join(f'F{j}' for j in range(i))}>::Result>);
    return WithResult<typename Types::Result>(
        SimplifyMiddle<Traits, (kInstantBits & ${bin(not_mask)})>(
            ${map}, std::tuple<>(), ${','.join(rest)}));
  }
% endfor
  else {
    return SimplifyMiddle<Traits, kInstantBits>(
        std::forward<P>(p),
        std::tuple<>(),
        ${",".join(f"std::forward<F{j}>(f{j})" for j in range(0,n-1))},
        whence);
  }
}
% endfor

///////////////////////////////////////////////////////////////////////////////
// SimplifyRight

% for n in range(2, max_steps):
template <
    template<typename> class Traits,
    uint32_t kInstantBits,
    typename P,
    ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto SimplifyRight(
    P&& p, ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))},
    DebugLocation whence) {
  using Types = SeqStateTypes<
      Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}>;
% for i in range(n-1, 0, -1):
  <%
  mask = (1 << i) - 1
  first = i == n-1
  if first:
    left = "std::forward<P>(p)"
  else:
    left = f"SimplifyLeft<Traits, (kInstantBits >> {i})>(std::forward<P>(p), {','.join(f'std::forward<F{j}>(f{j})' for j in range(0, n-1-i))}, whence)"
  %>
  ${constexpr_if(first, f"(kInstantBits & {bin(mask)}) == {bin(mask)}")} {
    return WithResult<typename Types::Result>(SeqMap<Traits>(
       ${left},
       ${",".join(f"std::forward<F{j}>(f{j})" for j in range(n-1-i, n-1))}));
  }
% endfor
  else {
    return SimplifyLeft<Traits, kInstantBits>(
        std::forward<P>(p),
        ${",".join(f"std::forward<F{j}>(f{j})" for j in range(0,n-1))},
        whence);
  }
}
% endfor

///////////////////////////////////////////////////////////////////////////////
// Simplify

% for n in range(2, max_steps):
template <
    template<typename> class Traits,
    typename P,
    ${",".join(f"typename F{i}" for i in range(0,n-1))}>
GPR_ATTRIBUTE_ALWAYS_INLINE_FUNCTION auto Simplify(
    P&& p, ${",".join(f"F{i}&& f{i}" for i in range(0,n-1))},
    DebugLocation whence) {
  using Types = SeqStateTypes<Traits, P, ${",".join(f"F{i}" for i in range(0,n-1))}>;
  static constexpr uint32_t kInstantBits =
      ${"|".join(f"(Types::NextFactory{i}::kInstantaneousPromise? {1<<(n-2-i)} : 0)"
        for i in range(0,n-1))};
  return WithResult<typename Types::Result>(
      SimplifyRight<Traits, kInstantBits>(
          std::forward<P>(p),
          ${",".join(
              f"std::forward<F{i}>(f{i})" for i in range(0,n-1))},
          whence));
}
%endfor

///////////////////////////////////////////////////////////////////////////////


}  // namespace promise_detail
}  // namespace grpc_core

#endif  // GRPC_SRC_CORE_LIB_PROMISE_DETAIL_SEQ_STATE_H
