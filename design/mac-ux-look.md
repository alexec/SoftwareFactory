# What the eye found

A71, 15 September 2026. T395. The other review, `mac-ux-review.md`, was a grep and said
so: the shell it ran in could not see the screen, so it found the disagreements a grep can
find and nothing was ever looked at. This one looked.

## How it was looked at

The app was running as it always is, on Alex's own desktop, on a Space this session is not
on. So the screen capture is desktop only and shows nothing; the window has to be asked for
by id. `CGWindowListCopyWindowInfo` gives the id, `screencapture -l <id>` takes the window
wherever it is, and the colours below are sampled out of that PNG rather than judged by
eye off a description.

```bash
/tmp/windows                                  # owner, id, size, from CGWindowListCopyWindowInfo
screencapture -x -o -l 1827 /tmp/sf-window.png
```

**One page was seen, the Dashboard**, in dark appearance, at 2031 by 857. That is the
honest limit of this pass: a session in a background launchd session can capture the window
but cannot click in it, and the rest of the app is behind a click. Capacity, a project, an
agent, the status board, light appearance, the smallest window and the largest Dynamic Type
are all still unlooked at. What follows is what one page showed, and it was worth the
trouble.

The screenshot is `screens/dashboard-dark-2026-09-15.png`.

## What is wrong

**The selection is system blue.** The selected sidebar row samples `#D4E8FE`. The house has
one colour and it is rust, `Paper.Tone.mark`, and `.tint(Color(.mark))` is set on the detail
side of the split view rather than on the whole window, so the sidebar's own selection is
still taking the system accent. It is the largest area of colour on the page and it is the
one colour that is not ours. Everything else on screen is warm.

**Four of eight agents say a shell command.** The line under an agent's name reads
`SLOT=~/.claude/...ump 2>&1 | tail -1`, `gh run view 349...led 2>&1 | tail -60`, and
`U=EC265A7E-FB...active --wifiBars`. `AgentLine.underTheName` ends on the terminal title,
and a tmux pane's title is the last command it ran. T295 put the task first and the status
report second, which is right, and then left the raw title as the third answer. For an agent
holding nothing and saying nothing, the honest line is silence or "Working", not the tail of
its own shell history.

**A sentence is truncated in the middle.** `Four pushed: T3...ecord (686bfb3).` and
`T395 Look at the M...ew was a grep`. `.truncationMode(.middle)` is right for a path, where
the ends are what identify it, and wrong for a sentence, where the front is what you read.

**Orange on dark paper is brown.** The Needs-you tint samples `#6F5A43`. Orange is the app's
one signal that a person is needed, and at 12 to 18 percent over a near-black ground it
comes out as a warm brown that reads as another shade of paper rather than as a flag. It
wants either more opacity in dark or the mark's own dark value.

**The dashboard is mostly empty.** Four tiles and one line, then 600 points of nothing. The
agent cards moved to the sidebar in T359 and the page they left has not been reconsidered.
It is the page you land on, so what it does with that room is worth a decision rather than
an accident.

## What is right

The ground is warm and it is paper: `#23221F` across the window and the sidebar, lighter
than the `1b1a18` token because Liquid Glass sits on it, and warm in the right direction
(red above green above blue) rather than a neutral black. The tiles' glass reads as one
material at one radius. The agents tile added in T392 says "1 has gone quiet" and is the
only tile on the page carrying news.

## What is still unlooked at

Everything behind a click, which is most of the app. Getting there needs a session in Alex's
own Aqua login session, or Alex clicking while a capture runs. The window's other pages, the
light appearance, the smallest window, and the largest Dynamic Type are the four that most
want an eye.
