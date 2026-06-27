# Classic Savings Ratio Model Plan

This is the working plan for improving the thesis and recommendation in the classic savings rates post.

It includes the synthesis from three review passes:

- New Yorker-style editor: make the flaw in `50/30/20` about time and structure.
- Math and stats review: make the ratio an output of real inputs, not the starting rule.
- Plain-language writer: explain the model with simple labels, then formulas.

## Core Thesis

The old savings rules are dubious because they freeze time.

They act like one budget split should work for a household in debt, a household building its first emergency fund, a household with two years of core expenses saved, a single renter in San Francisco, and a dual-income couple with no debt.

That is the real flaw.

The problem is not only that `50/30/20` has the wrong percentages. The problem is that it has no path. It does not say what to do in year one, year three, year five, after debt is gone, after rent changes, after a raise, after a partner enters the picture, or after the emergency fund is full.

The replacement thesis:

> Use ratios as phases, not rules. Your current ratio shows where you are. Your next ratio shows where you are trying to go.

## Reader Takeaway

Do not ask:

```text
What percentage should I save forever?
```

Ask:

```text
What phase am I in?
What target am I trying to hit?
What has to change for the next phase to become real?
```

## Core Model

Start with real numbers.

```text
take-home pay
- core life
- optional life
= saving, investing, and debt paydown capacity
```

The ratio is the output:

```text
core_ratio = core_life / take_home_pay
want_ratio = optional_life / take_home_pay
save_ratio = saving_debtpaydown_capacity / take_home_pay
```

Debt needs two categories:

```text
core life = survival bills + debt minimums
saving/debt paydown = emergency fund + investing + extra debt principal
```

That keeps the math honest. Minimum debt payments are required bills. Extra principal is how the household buys back future cash flow.

## Emergency Fund Formula

The target:

```text
core life x target months = emergency fund target
```

The gap:

```text
emergency fund target - current emergency fund = emergency fund gap
```

The time:

```text
emergency fund gap / monthly cash reserve contribution = months to target
```

Use `cash reserve contribution`, not total saving capacity, because some money may also be going to extra debt principal, 401(k), Roth IRA, taxable investing, or an employer match.

## Core Costs

Core costs are the bills that cannot realistically pause:

```text
core_life =
  rent_or_mortgage
+ utilities
+ internet
+ phone
+ groceries
+ car payment
+ gas
+ car insurance
+ health insurance / medical minimums
+ debt minimums
+ childcare / dependents
+ other bills that cannot pause
```

## Phase Ladder

Ratios are phases, not identities.

| Phase | Ratio | Meaning |
| --- | ---: | --- |
| Triage | `70/10/20` | Current reality is expensive. Not ideal, but honest. |
| Repair | `60/10/30` | Costs came down, income rose, debt fell, or car costs fell. |
| Build | `50/10/40` | The plan is working. Safety is growing. |
| Aggressive build | `40/10/50` | Strong income, controlled core costs, fast wealth building. |
| Maintenance | `40/30/30`, `50/25/25`, or `40/20/40` | Targets hit. Debt gone. Still saving, but life can loosen. |

Important warning:

`70/10/20` is not the goal. It is the honest starting point for some households.

## Phase Gates

Do not move phases just because time passed.

Move phases because the balance sheet changed.

| Move | Only happens when |
| --- | --- |
| `70/10/20` to `60/10/30` | rent falls, income rises, debt falls, or car cost falls |
| `60/10/30` to `50/10/40` | the emergency fund is past three to six months and debt is improving |
| `50/10/40` to `40/10/50` | core costs are controlled and saving speed is high |
| build phase to maintenance | high-interest debt is gone and the 12-24 month target is funded |

## What Moves The Ratio

The strongest levers:

- raise income
- lower rent
- add a roommate or partner
- kill debt
- reduce car cost
- keep fixed costs flat after a raise

The key relationship:

```text
if core_ratio falls, save_ratio can rise by the same amount
unless wants expand first
```

## Roommate Impact

A roommate or partner is not just cheaper rent. It can change the whole speed of the plan.

Formula:

```text
monthly rent saved / monthly take-home pay = savings-rate gain
```

Example:

```text
$1,850 rent saved / $11,000 take-home = 16.8 percentage points
```

In annual dollars:

```text
$3,700 one-bedroom alone - $1,850 one-bedroom split = $1,850/month
$1,850 x 12 = $22,200/year
```

That can be a whole emergency-fund phase.

## Raise Capture

A raise only helps if fixed bills do not rise with it.

Formula:

```text
raise_capture_rate =
  amount of new take-home saved / increase in take-home pay
```

Example:

```text
$800 saved from a $1,000 monthly raise = 80% raise capture
```

That is how a household moves from `60/10/30` toward `50/10/40` without feeling like life got smaller.

## Partner / DINK Math

A partner changes household math in two ways:

```text
household take-home rises
shared costs do not double
```

Formula:

```text
household core ratio =
  shared core costs + individual core costs
  divided by combined take-home pay
```

Warning:

Dual-income households should still run a one-income stress test:

```text
Can one income carry the core bills for a while?
```

If not, the emergency fund target should be larger.

## Scenario A: $100k In San Francisco

This person may start at `70/10/20`.

That is not the goal. It is the diagnosis.

| Year | Ratio | What changed |
| --- | ---: | --- |
| 1 | `70/10/20` | Rent is too high. Saving exists, but progress is slow. |
| 2-3 | `60/10/30` | Roommate, cheaper neighborhood, raise, debt reduction, or some mix of those. |
| 4-5 | `50/10/40` | Core costs are under control. Emergency fund starts moving faster. |

Main point: at `$100k` in San Francisco, the plan is not "try harder." The plan is change the structure.

## Scenario B: DINK Couple

This household starts at `50/10/40`.

| Years | Ratio | Why |
| --- | ---: | --- |
| 1-2 | `50/10/40` | Build emergency fund, kill debt, control lifestyle. |
| 3-4 | `40/10/50` | Shared housing and dual income create room. Push hard. |
| 5+ | `40/30/30` | Debt free, target hit, 401k maxed, still saving. Life can loosen. |

This is where `40/30/30` makes sense.

It is not the starting point. It is the reward for hitting the safety target.

## Scenario C: $200k Single In San Francisco

This person may be able to start at `40/10/50`.

At `$11,000` monthly take-home:

```text
40% core = $4,400
10% wants = $1,100
50% save/invest = $5,500
```

A 24-month core target:

```text
$4,400 x 24 = $105,600
```

If the household sends the full `$5,500` to the cash target:

```text
$105,600 / $5,500 = about 20 months
```

After the target is hit, the household may move to:

```text
50/25/25
```

That means more housing and life flexibility, but still `$2,750` per month saved on `$11,000` take-home.

## Visual Plan

Add these visuals to the post:

1. **Ratio Ladder**
   Show `70/10/20 -> 60/10/30 -> 50/10/40 -> 40/10/50 -> maintenance`.
   Make clear that this is balance-sheet progress, not moral progress.

2. **Formula Cards**
   Show:
   - `core life x target months = emergency fund target`
   - `gap / cash reserve contribution = months to target`
   - `rent saved / take-home = savings-rate gain`
   - `new take-home saved / raise = raise capture`

3. **San Francisco Housing Stress Test**
   Keep the current card graphic. It works.

4. **Five-Year Track Cards**
   One card each:
   - `$100k SF: structure-change plan`
   - `$200k single SF: fast-build plan`
   - `DINK couple: build then loosen plan`

5. **Loosen-Up Gate**
   A checklist showing when `40/30/30` or `50/25/25` becomes reasonable.

## Implementation Phases

Phase 1: Update the opening thesis.

- Add the idea that the old rule freezes time.
- Say plainly that the ratio should move as the household changes.

Phase 2: Add the ratio model.

- Explain current split as an output.
- Add formula cards.
- Separate debt minimums from extra principal.

Phase 3: Add the ratio ladder visual.

- Show phases.
- Make `70/10/20` a diagnosis, not a recommendation.
- Add phase gates.

Phase 4: Keep and support the San Francisco stress test.

- Keep the current visual.
- Connect it to the phase model.
- Show roommate/partner math as a direct savings-rate gain.

Phase 5: Add five-year scenario cards.

- `$100k SF`: structure-change plan.
- `$200k single SF`: fast-build plan.
- DINK couple: build then loosen plan.

Phase 6: Replace the old "after emergency fund is full" section.

- Add a clearer loosen-up gate.
- Explain maintenance ratios.
- Show why `40/30/30` and `50/25/25` can be earned later.

Phase 7: Tighten the close.

- Change "Use rules as tools" to "Use ratios as tools."
- End with moving from fragile to flexible.

## Point To Preserve

The goal is not one perfect ratio.

The goal is moving from fragile to flexible.
