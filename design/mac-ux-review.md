# The Mac app's styles, and where they disagreed

T343, 15 September 2026. A review of what the Mac app looks like, why it read as mixed,
and what was changed.

## What was wrong

Nothing here was wrong on its own. Each measurement was written where it was used, by
whoever was there, and each one was reasonable. Together they read as an app made by
several people who had not met.

**Corners.** A card was 18 points of corner in fifteen places and 14 in one. A box inside
a card was 12 in three places and 8 in two. A chip was a capsule in five places and a
rounded rectangle in the sixth. Curves are the thing the eye picks up fastest and the
thing nobody notices they are noticing.

**One word, two buttons.** "Add" was `.glassProminent` on the dashboard and in the
dictation popover, and `.glass` on the Capacity page and on a project's parked row. The
same word, the same job, the primary action of a small form, styled two ways.

**One piece of glass that was not.** The banner that says a write failed used
`glassEffect(in:)` rather than `glassEffect(.regular, in:)`, the only one in the app, at
its own radius.

**Padding.** Pages are 24, cards are 16, sheets and popovers are 20. The dictation
popover was 18.

## What was changed

`App/Sources/Style.swift` is the scale, with what each size is for written down:

| | | For |
| --- | --- | --- |
| `Style.card` | 18 | Anything on glass in its own right: an agent, a document, a question, a stat tile, a banner. |
| `Style.panel` | 12 | A box inside a card, always tighter than the card around it or the two curves fight. |
| chip | capsule | One word with a background. As round as it is tall. |
| `Style.page` | 24 | A page's own margin. |
| `Style.cardPadding` | 16 | A card's edge to its words. |
| `Style.sheetPadding` | 20 | A sheet or a popover, which is a page rather than a card. |

Every literal corner in the Mac app now names one of these, so the next one is a decision
rather than a guess. Both stray radii, both stray panel radii, the rounded-rectangle tab,
the two quiet "Add" buttons and the bare glass were brought in line.

## What was left alone

**`.plain` against `.borderless`.** Twelve buttons are plain and nine are borderless, and
that reads as a mess in a grep and as a rule on screen: plain is a whole surface you
click, a card or a name that opens something; borderless is a small action inside
something else, Take back, Folder, Delete, Change. That is a real distinction and it is
being kept.

**The intro sheet's 28 points of padding.** It is the one screen that is only words, read
once, and it is meant to breathe.

**Two title sizes.** `.title2.weight(.semibold)` names a page, `.title3.weight(.semibold)`
names a thing on it, an agent or a project. That is a hierarchy, not a disagreement.

## What is not covered

This is what a static read can see. Nothing here was looked at on screen: the shell this
ran in has no screen recording permission, so the grep found the disagreements and the
eye has not confirmed the result. Spacing rhythm, the weight of the glass against the
Liquid Glass material behind it, and whether a 460-point document browser inside a
scrolling list feels right are all things to judge by looking.
