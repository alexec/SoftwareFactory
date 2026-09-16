# The UX brief

A71, 15 September 2026. One brief for the whole of what a person sees: the Mac app, the
iPhone, the Lock Screen, the documents. It gathers what has already been settled in
twenty-odd tasks and in Alex's own asides, states the shape they add up to, and says what
is still wrong. A new screen is checked against this. Where this brief and a note in
`CLAUDE.md` disagree, the note wins and this file is out of date.

## 1. What the app is for

A person runs a software factory from one window. Agents do the work. The person makes
the calls that are theirs to make and nothing else.

Everything on screen serves one of four jobs, and a screen that serves none of them is a
screen to argue for:

1. **Say what needs me.** A question with options, a document nobody has read, a message
   that has not landed, an agent that has stopped.
2. **Show me the floor.** Who is here, what they are on, how the Mac is holding up.
3. **Let me steer.** Rank a backlog, add a task, park one, start an agent, stop one, put a
   project on hold.
4. **Let me read what was written.** A plan, a finding, a status report, a conversation.

Job 1 is the product. The other three are how you get back to it.

## 2. The person, and the three moments

One person, Alex, who is the product manager and the tester and nobody's colleague on
this floor. He is in one of three places, and each one is a different app.

**At the Mac, looking.** He came to the window on purpose. He can read a whole
conversation, drag a backlog into the order he wants, open a document on paper. Density is
fine here. Nothing needs to shout.

**At the Mac, not looking.** The window is behind something else and eight agents are
working. This is most of the day. The only things that may reach him are a question and a
banner, and they reach him through macOS rather than through the window.

**Away from the Mac.** A phone in a pocket, a Lock Screen, fifteen seconds of attention
while the kettle boils. He can answer a question, add a task he has just thought of, and
see whether the floor is alive. He cannot and should not do anything else.

The iPad, when it comes, is the first moment on a screen you can pick up. It is not a
fourth thing.

## 3. The principles, stated once

These are not new. They are the arguments the app has already had, written where a new
screen can be held against them.

- **A recommendation is marked, never chosen.** No option is preselected, no timeout
  applies one on his behalf. The exception is a permission request an agent is frozen on,
  where ten minutes of silence takes the recommendation, and that recommendation is always
  allow once and never allow always. A standing decision is not one to make for somebody
  because they were out of the room.
- **Nothing is drawn for nothing.** No bell until an agent rings it, no count until
  something is waiting, no empty section holding its place. A badge that can only go up is
  one people learn to ignore.
- **A number answers a question.** A sidebar row carries the backlog count because it
  answers where there is work left to pick up. It lost the blocked and in-progress counts
  because reading twelve small numbers to find a project is not reading.
- **The screen explains itself.** The first-run sheet is the only place that explains.
  There is no instructional text on a working screen, no row of hints under a field, no
  pane with a button saying Open a shell.
- **Say it once.** Greying and shrinking say the same thing twice, so a read card is
  smaller and is not grey. Grey also says you cannot have it.
- **A control that can never work says come back later.** Not disabled. A stopped Cursor
  agent is not offered a Start that would fail; it is told why not.
- **Ask before the system asks.** Every permission gets a primer in the app's own voice,
  at the moment of use, with a calm path to Settings when it is denied.
- **The work is the agent's word.** The person adds, ranks, parks and deletes. Only an
  agent says in progress and done.
- **Private, and the app says so by never asking.** No account, no telemetry, no purchase.

## 4. The material

**Paper under glass.** A warm near-white ground, a warm near-black ink, one rust mark.
It goes under the whole app: the window, the sidebar, Settings, the sheets. Liquid Glass
keeps its translucency and sits on the paper, so the theme is what shows through the glass
rather than a second idea beside it. Dark is its own paper and not a white page dimmed.

Eight tones, in `Paper.Tone`, and nothing else is a colour:

| | Light | Dark | For |
| --- | --- | --- | --- |
| `paper` | `fbfaf6` | `1b1a18` | the ground |
| `ink` | `22201c` | `e6e1d8` | what is written |
| `quiet` | `6d675d` | `9c958a` | a caption, a date, something said quietly |
| `faint` | `968f83` | `77716a` | a count, a hint, something you read when you go looking |
| `rule` | `e0dbd0` | `35322d` | a line across the page |
| `edge` | `cfc8ba` | `45413a` | the edge of something sitting on the page |
| `block` | `f1ede4` | `26241f` | a block set in: code, a quote, a tool call |
| `mark` | `8a5a2b` | `d0a271` | the one colour, for a link or a mark |
| `alarm` | `c2410c` | `fb923c` | a person is needed, and nothing else |

Three other palettes were tried and this is the one picked with all of them in front of
him. It is close to Claude's own and that was raised, weighed and settled. Leave it alone.

**Measurements** come from `Shared/Style.swift` and are not written where they are used:
`card` 18, `panel` 12, `page` 24, `cardPadding` 16, `sheetPadding` 20, and a chip is a
capsule because a chip is as round as it is tall. A new corner names one of these or it is
a decision worth arguing for.

**Type.** `Style.Text`, beside the corners, nine sizes with what each is for: `page` names
a screen, `thing` names something on it, `row` is what a row says, `rowName` is the name of
one, `quiet` is a date or a count, `machine` is a path or a command, `gauge` is a number
read across the room, `welcome` is the one word on a first-run sheet, `tiny` is the smallest
thing that is still a control. Every one is a Dynamic Type style rather than a number, so
all of it grows when the person's text does. **One family, the system's** (T447): the
conversation was set in a serif and read as a page of a book inside an app that is not one.
A document opened on paper keeps its serif, because that is a page being read rather than a
screen being used. Anything anybody said is set at the measure, 690 points, which is a line
you can read to the end of.

**The alarm.** `alarm` means a person is needed and nothing else: an open question's
count, a task blocked, a report past its hour, an agent asking permission. It was
`Color.orange` in thirty-three places and in the palette in none, so nobody was managing
it, and on dark paper a twelve percent wash of the system's orange sampled `#6F5A43`, a
warm brown a shade off the ground. On dark, a wash is not a flag: a mark is. The sidebar's
question count is a solid alarm capsule with paper-coloured digits rather than a quarter
strength tint. (T408.)

Two sets of colour are not the alarm and are left alone. The Capacity page's gauges are a
traffic light, green to orange to red, where orange is the middle of a scale and is read
beside the other two. And the activity dot is its own vocabulary, one file for both apps in
`Shared/AgentActivityDot.swift`, so a stopped agent is the same colour on the Mac and on
the phone. Neither is a signal that a person is needed, and painting them with the alarm
would spend it.

**Motion.** Two kinds. State arriving, which is a fade or a slide and is over in under a
quarter of a second, and the bell, which wiggles because it wants you. Nothing else moves.
Every animation respects Reduce Motion.

**Sound.** There is none, and that is the design. The bell is a mark on a card. Silence is
better than a sound that turns out to be wrong at four in the afternoon.

## 5. The hierarchy

What a screen says first, and what it is allowed to say loudly. Four rules, written down
because the app was already breaking all four and nothing said it was wrong.

**The most important object on a page is the largest thing on it.** The dashboard puts four
stat tiles above Needs you, the numbers set in `.largeTitle` and the heading of the section
that matters in `.title2`. So the largest type in the app is a number, and on the day it was
looked at three of the four read zero. A question an agent is stuck on is the product; a
count is a fact you glance at. Needs you goes first and full width, and the tiles are quieter
than it.

**One kind of information, one altitude.** What is waiting is reported in three places at
once: the two counts beside the factory's name in the title bar, the tiles on the dashboard,
and a badge on each project row. Three heights for one class of fact means a person either
scans all three or trusts none. One of them owns it.

**Navigation and status are different layers.** The sidebar's job is where to go. Nineteen
projects at one line each and eight agents at two lines each means more than half its height
is a status feed, and the list of places runs out of window before the alphabet does. A list
of places may carry a count. It may not carry a feed.

**Loudness is reserved.** Orange means a person is needed and nothing else, so orange is the
loudest thing in the window and everything else is ink, quiet and faint. Today the loudest
thing is the blue selection, which is not even one of the eight tones, and the second loudest
is a Needs-you tint that samples brown on dark paper. Navigation chrome is outranking the
alarm.

A corollary that follows from all four: a row that shows something has to be able to show
nothing. A second line under an agent's name that falls back to its last shell command is
noise drawn at the weight of news, and the fix is silence rather than a smaller font.

## 6. The screens, and the one job each has

### The window

A split view. The sidebar is a list of places to go and not a status report: Dashboard,
Capacity, No project, then the projects, each with the agents on it hanging underneath,
working first and stopped after. An agent is its name, its dot, and a line for every task
in its name; an agent holding nothing says the first line of its status report instead. A
project row is its name, its backlog count in `faint`, and a count in orange when a
question is waiting.

### Dashboard

Ready on open. Needs you first, as a horizontal strip, then the stat tiles, then the
agents on the floor as cards. It is the page you land on because it is the page that
answers job 1. Empty states show the shape of what will fill them.

### A question

A card with the words, the options as buttons, the recommended one marked, and one field
under them: type before clicking and it rides along as a note, send it alone with Answer
with this and it is the answer. A link on the question is filed as a document, so the
thing to read is here rather than somewhere else. Answered questions fold to one line and
only the newest three stay.

### An agent

A band and two columns. The band is under the name, full width, and says what it is on,
what it holds, its messages, what it is running with. Not its pid and not its session id,
which look useful and are not. The left column is the agent at work: a terminal for one
the app holds through tmux, the folded conversation for one that speaks ACP. The right
column is what the agent has written, one document on paper at a time, with tabs across
the top, and it is not drawn at all for an agent that has written nothing.

The conversation is set on paper: a serif for everything anybody said, the measure, a tool
call as a block set into the page rather than a card on top of it, thinking folded away
behind a button because it is nine tenths of the words and a tenth of the interest. Only
the most recent tool call of a run is drawn and the card says how many went before it.

The field at the bottom goes straight to the agent. This is a person typing on the agent's
own page, which is what the terminal was, and the terminal never queued.

### A project

The backlog down the middle and the documents in a column beside it, with a grip between
them whose width is remembered. Add at top or bottom, drag to rank, a state menu, notes
under rows, Start an agent on this from any row. The first word of what you type is the
work and there is no picker: it is one of seven words or it is Code.

### Capacity

The verdict, what each kind of work would be told, then one grid of cards: the Mac's own
readings and every leasable resource in the same shape, a name and a coloured utilization
line. Agents are a resource like any other and the stepper that sets how many may be on
the floor lives on that card.

### Settings

How it works on top, always, because it is the one thing that explains and he re-reads it
as it changes. Then in-app against Terminal, iCloud, the store, Asking, and a Developer
section only in Debug.

### First run

One sheet, once. The name and what it is, how you use it in a few steps, why this one,
closing on Private and free forever. Dismissed for good, and reachable from Settings.

### The phone

The Mac seen from somewhere else, so it is built to the same measurements, set in the same
paper, and coloured the same way. Needs you, the floor, a project's backlog, an agent's
conversation with a field on glass. Thinking is not shown there: there is no room to fold
it away. What needs the Mac is hidden while the Mac is out of reach rather than queued,
because a button that will happen later is worse than a button that is not there.

### The Lock Screen

One Live Activity while a question is open, with the options as buttons, answered without
unlocking. The newest question and how many more wait. 160 points, and the layout is sized
for that.

## 7. How the app talks

Alex's voice, which is a rule and not a style: no em dashes, no template phrases, say why
and not only what, name who is doing the thing. A refusal says what to do instead, so
"Mailbox full" carries the reason and the artifact size limit says to put the long one in
the repo and file a link. A number is the device's number: units, dates and times come
from Language & Region and never from an assumption about where he lives.

## 8. The states a screen has to hold

Every list and every card answers all of these or it is not finished.

- **Empty**, which shows the shape of what will fill it.
- **Waiting**, which says what it is waiting for and never spins without a subject.
- **Stale**, which is a Live Activity past fifteen minutes or a report past its hour, and
  says so in orange rather than quietly lying.
- **Out of reach**, which is the phone off the Mac's network: it says the transcript lives
  on the Mac rather than drawing an empty conversation.
- **Failed**, which is a write that did not land, on glass, at `Style.card`.
- **On hold**, which blocks no tool and puts a line at the end of every reply.
- **Sandboxed**, which is the store build saying it put the command on the clipboard
  rather than pretending it started something.

## 9. What is wrong now, ranked

Rewritten on the evening of 15 September 2026, after a night of work took six of the
original eight off the list. What is left is what nobody has done rather than what nobody
had noticed.

1. **Nothing has been looked at but the Dashboard and an agent's page.** T395 got that far:
   a background session can capture the window by id wherever it is and cannot click in it.
   Capacity, a project page, the status board, the light appearance, the smallest window and
   the largest Dynamic Type are all unseen. T410 waits on Alex for exactly this.
2. **The floor is still drawn twice.** `DashboardView` on the Mac and `PhoneRootView`
   beside it. The question card came into `Shared` in T394 and the agent card did not,
   because it is two presentations rather than one drawn twice: a grid card with actions on
   the Mac, a navigation row on the phone. That is a design decision to take, not a tidy-up.
3. **The agent's page has never had a pass as a whole.** It is the busiest surface in the
   app and it has changed on nearly every task tonight: the band lost the tasks and the
   messages panel, the mode and the CLI moved under the field, Stop and Archive left, the
   field gained a microphone and a drop target. Each change was right on its own. Nobody has
   looked at the result.
4. **Two ways of holding an agent, and they must not become two mental models.** A terminal
   and a folded conversation is the right split, one being a pty and the other JSON. Any new
   control goes on both or on neither.
5. **The Dashboard is three tiles and a line when nothing needs you.** T409 turned it the
   right way up and deliberately did not fill the room, because inventing something to show
   when the floor is quiet is the same mistake as a badge that only goes up. Still worth a
   decision rather than an accident.

Off the list tonight, and why, because a brief that only grows is one nobody trusts: the
doorless pages went in T392, the alarm colour is in the palette after T408, the shell
commands are off the sidebar after T407, the type scale is written into `Style.Text` after
T459, the serif went in T447, and the dot is four states off the daemon rather than five off
a ten-minute proxy after T423 and T425.

## 10. How to tell it worked

- He opens the window and knows within two seconds whether anything needs him.
- He answers a question from the Lock Screen and the agent moves on before he puts the
  phone down.
- Nothing on screen is the same thing said twice.
- A screen he has not seen before is still obviously this app, because it named its
  corners, used the eight tones, and said its one sentence in his voice.
