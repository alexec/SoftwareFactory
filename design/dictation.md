# Talking to the factory

A design brief. T316, 15 Sep 2026.

You hold a key, say what you want, and the factory works out which project you mean and
what to do about it. Today you can only dictate into a text field, and even that is
switched off, because it did not work well (T91).

## What this is for

You think of work away from the keyboard: walking, on the phone, halfway through
something else. Typing it means opening the app, finding the project, clicking Add,
typing, and by then the thought has moved on. Most of what you dictate is one sentence
that belongs on one backlog, and the factory already knows every project's name and every
task's number. It should be able to work the rest out.

## The one rule

**Dictation proposes. It never commits.** What you said becomes a row you can see and
correct, with a Confirm on it, not a task that has already been filed. A misheard project
name that quietly files work on the wrong backlog is worse than typing it yourself,
because you will not find out for a week.

The exception is reading. "What is A61 doing" changes nothing, so it just answers.

## What you say, and what happens

Hold the microphone, or hold a hotkey anywhere in the Mac app. The words appear as you
say them, the way `DictateField` already shows them. Let go, and the factory shows you
what it understood:

> **Sleeper Train** · Add · Fix &nbsp;&nbsp; *Fix the timetable scrolling past the end*
> &nbsp;&nbsp; [Confirm] [Throw away]

Everything on that row is editable. The project is a picker, the verb is a picker, the
words are a field. If you edit it and confirm, the factory learns nothing and does not
try to: there is no training loop here, just a form you can fix.

## Working out the project

Three routes, in this order.

1. **You said its name.** `Projects.exact` on the words first, then `Projects.nearMiss`.
   That near-miss code was written for typing slips, and a recogniser makes the same
   shape of mistake: it already knows "NightSleeper" is a slip for "Sleeper Train", and
   it will know "Stormy Knight" too. This is the whole reason this is worth building
   with no model in it.
2. **You are looking at one.** If the open page is a project, or an agent working on a
   project, that is the project unless you named a different one.
3. **Neither.** The row shows an unset project picker and will not confirm until you
   choose. Nothing is guessed silently.

The name can sit anywhere in the sentence. "On Sleeper Train, fix the timetable" and
"fix the timetable on Sleeper Train" are the same sentence.

## Working out what to do

The first word is the verb, which is how people talk and how `WorkField` already reads a
typed task.

| You say | What happens |
| --- | --- |
| *(no verb)* "the timetable scrolls past the end" | Add a task. This is the common case. |
| "Add …", "File …" | Add a task. |
| "Fix …", "Design …", "Plan …", "Review …" | Add a task, and that is its work. |
| "Park T509", "park the timetable one" | Park it. |
| "Unpark …", "Put T509 back" | Back to the backlog. |
| "Top T509", "Bump the timetable one" | Move it to the top of the backlog. |
| "Hold Sleeper Train", "put Sleeper Train on hold" | Project on hold. Always confirms: since T309 this stops the agents on it. |
| "Nudge A61", "tell A61 to take the next task" | Nudge that agent. |
| "What is A61 doing", "how is Sleeper Train" | Read it back. Changes nothing, so no confirm. |

Note what is missing: you cannot say a task is done or in progress. `Backlog.personMaySet`
is backlog and parked, because the agent doing the work is the one who says it is done.
Voice does not get a power the rest of the app refuses.

## Naming a task out loud

Two ways, and both already exist.

- **By number.** "T509". The numbers were given short names for exactly this: say it,
  type it, or give it to an agent.
- **By its words.** "the timetable one" matches against the titles on that project. If
  one clearly wins, it is on the row. If two are close, the row shows both and you pick.
  Never the closest of a bad lot.

## Several things in one breath

You dictate in lists, so one dictation becomes several rows. Split on "and then", "also",
"next", and on a long pause. Each row confirms on its own, and there is a Confirm all.
Getting one wrong costs you that one, not the lot.

## Keep the words

The sentence you actually said goes in the task's note, under the title. If the split was
wrong, or the verb was read as part of the title, what you said is still there to read.
This is the same reason `TaskTitler` stopped asking a model for a title: the words
themselves beat anything that rewrites them.

## No model in the middle

Two attempts at putting intelligence between you and your words have been backed out of
this app already. T91 took dictation off the add rows. `TaskTitler` dropped Apple
Intelligence's title extraction because it was unreliable enough to be worse than the
words themselves.

So: on-device recognition through `SpeechAnalyzer`, which is already written, and then
plain rules over the text. Name matching that exists. Task numbers that exist. A verb at
the front. If the rules find nothing at all, the fallback is to file what you said as a
task on the project you are looking at, which is what you wanted most of the time anyway.

If a model ever earns a place here, it earns it by proposing into the same row, where you
can see what it did before it happens.

## On the phone

The phone is where this pays off most, because the phone is where you are when you think
of something. Hold the microphone on the floor view, say it, confirm. Both routes already
carry a task: `/api/task` when the Mac is on the network, CloudKit when it is not. A task
added over iCloud carries no number until the Mac adopts it, which is fine: you will be
naming it by its words for the next minute anyway.

The one worth building after that is answering a question from the Lock Screen. An open
escalation is an agent standing still right now, the Live Activity is already there with
the options on it, and "the second one" or "go with glass" matches an option title.

## What to build first

1. The proposal row, with project, verb and words, all editable, and Confirm. Nothing
   behind it: a typed sentence goes in, a task comes out. This is the whole design, and
   it is testable in the package without a microphone.
2. The rules: project from the words, project from the page, verb, task by number, task
   by words. All pure functions, all tested.
3. The microphone on the Mac, held.
4. Splitting one dictation into several rows.
5. The phone.

Stop after each one and see whether the next is still worth it.
