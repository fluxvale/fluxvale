defmodule FluxValeWeb.Storybook.Components.Card do
  @moduledoc """
  Card stories — the primary grouping surface.
  """

  use PhoenixStorybook.Story, :component

  def function, do: &FluxValeWeb.CoreComponents.card/1
  def render_source, do: :function

  def template do
    """
    <div class="max-w-sm"><.psb-variation/></div>
    """
  end

  def variations do
    [
      %Variation{
        id: :default,
        description: "A card with its default padding",
        slots: [
          """
          <h3 class="font-semibold text-ink">Forgejo</h3>
          <p class="mt-1 text-sm text-ink-muted">A lightweight software forge — your own GitHub, minus the rent.</p>
          """
        ]
      },
      %Variation{
        id: :wallet,
        description: "Composed: card + balance + action (the billing wallet)",
        slots: [
          """
          <h3 class="text-sm font-medium text-ink-muted">Balance</h3>
          <p class="mt-1 text-3xl font-bold tracking-tight text-ink">$42.00</p>
          <p class="mt-3 text-xs text-ink-subtle">Credits never expire and are non-refundable.</p>
          """
        ]
      },
      %Variation{
        id: :hover_lift,
        description:
          "Link-wrapped card pattern (#277): a real link carries the card — hover lifts (the rise is motion-safe; the elevation step stays for reduced motion), focus-visible shows the outline. Tab to it.",
        template:
          ~s|<a href="#hover-lift-demo" class="block rounded-panel outline-offset-2 outline-focus focus-visible:outline-2"><.psb-variation/></a>|,
        attributes: %{
          class:
            "transition-[box-shadow,translate] duration-(--motion-base) ease-(--motion-ease-out) hover:shadow-md motion-safe:hover:-translate-y-1"
        },
        slots: [
          """
          <h3 class="font-semibold text-ink">Forgejo</h3>
          <p class="mt-1 text-sm text-ink-muted">A lightweight software forge — your own GitHub, minus the rent.</p>
          """
        ]
      }
    ]
  end
end
