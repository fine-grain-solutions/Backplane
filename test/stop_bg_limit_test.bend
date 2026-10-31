import Base
import ./check.bend as C
import ../src/core/json.bend as J
import ../src/core/model.bend as M
import ../src/core/fallback.bend as FB
import ../src/core/hub.bend as B

# A Claude turn that ends as a quota limit (Fallback.limited, the chain-on
# path, and ProviderResume.hold, the plain-wait path) stops the background
# tasks it left at work the same way Retire.stop.f does (Bg.stop.outs), so
# a shell left running cannot wake the thread later once it finishes.

def base(+agent: String, +bg: String) -> M.State:
  M.State.replay([M.ProjectCreated{"p1", "p", "/p", 1n}, M.ThreadCreated{"t1", "p1", "x", M.Local{}, "", "", agent, "", 1n},
    M.TurnChanged{"t1", M.Running{}, 2n}, M.WorkSet{"t1", "bg", bg, 2n}], M.State.empty())

def two() -> String:
  "b1\tsleep 600\tc1\tsleep 600\tshell\nb2\tnpm run dev\tc2\tnpm run dev\tshell"

def lim() -> FB.Limit:
  FB.Limit{"claude", "usage limit reached", 0n}

def stops(os: List<&2, B.Out>) -> List<&2, String>:
  match os:
    case Nil{}:
      Nil{}
    case B.AgentSend{_, +line} <> +t:
      +o = Maybe.default(&2, J.Json, J.Json.parse(line), J.Null{})
      +r = J.Json.get_obj(o, "request")
      Bool.pick(List<&2, String>, String.eq(J.Json.get_str(r, "subtype", ""), "stop_task"), J.Json.get_str(r, "task_id", "") <> stops(t), stops(t))
    case _ <> t:
      stops(t)

def outs(st: B.Step) -> List<&2, B.Out>:
  match st:
    case B.Step{_, os}:
      os

def fallback(+s: M.State) -> String:
  String.join(stops(outs(B.Fallback.limited(s, 5n, "t1", lim()))), ",")

def resume(+s: M.State) -> String:
  String.join(stops(outs(B.ProviderResume.hold(s, 5n, "t1", lim(), B.Step.none()))), ",")

def main() -> IO(Unit):
  do IO<Unit>:
    C.Check.str("fallback chain limit stops both", fallback(base("claude", two())), "b1,b2")
    C.Check.str("provider-resume wait stops both", resume(base("claude", two())), "b1,b2")
    C.Check.str("fallback chain limit, nothing at work", fallback(base("claude", "")), "")
    C.Check.str("provider-resume wait, nothing at work", resume(base("claude", "")), "")
    C.Check.str("codex fallback limit sends nothing", fallback(base("codex", two())), "")
    C.Check.str("codex provider-resume wait sends nothing", resume(base("codex", two())), "")
