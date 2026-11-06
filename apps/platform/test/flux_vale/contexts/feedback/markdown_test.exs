defmodule FluxVale.Feedback.MarkdownTest do
  @moduledoc """
  The feedback renderer's contract (fluxvale/fluxvale#488): Markdown
  basics render, every hostile class stays inert, and legacy plain-text
  bodies keep their single newlines.

  The hostile pins are regression alarms, not shape checks: each one
  fails under the specific mutation that reintroduces the class it
  pins (raw HTML via unsafe rendering, scheme gaps via ammonia's
  default allowlist, images via a lifted rm_tags, line-break collapse
  via a dropped hardbreaks, and the whole sanitizer via a dropped
  sanitize pass).
  """

  # Pure rendering — no DB, no conn.
  use ExUnit.Case, async: true

  alias FluxVale.Feedback.Markdown

  # --- Markdown basics ----------------------------------------------------------

  test "emphasis and strong render" do
    assert Markdown.render("*em* and **strong**") ==
             "<p><em>em</em> and <strong>strong</strong></p>"
  end

  test "links render with their href and text" do
    assert Markdown.render("[site](https://example.com)") ==
             "<p><a href=\"https://example.com\" rel=\"noopener noreferrer\">site</a></p>"
  end

  test "mailto links render" do
    html = Markdown.render("[mail](mailto:hi@example.com)")

    assert html =~ "href=\"mailto:hi@example.com\""
    assert html =~ ">mail</a>"
  end

  test "unordered and ordered lists render" do
    html = Markdown.render("- one\n- two\n\n1. first\n2. second")

    assert html =~ "<ul>"
    assert html =~ "<li>one</li>"
    assert html =~ "<li>two</li>"
    assert html =~ "<ol>"
    assert html =~ "<li>first</li>"
    assert html =~ "<li>second</li>"
  end

  test "inline code renders" do
    assert Markdown.render("use `mix ci`") == "<p>use <code>mix ci</code></p>"
  end

  test "fenced code renders as a pre block" do
    html = Markdown.render("```elixir\n{:ok, :ok}\n```")

    assert html =~ "<pre><code class=\"language-elixir\">{:ok, :ok}\n</code></pre>"
  end

  test "headings render" do
    assert Markdown.render("# Top\n## Second") == "<h1>Top</h1>\n<h2>Second</h2>"
  end

  # --- Hostile classes (the security posture is the spec) ------------------------

  # Script injection: the tag and its content vanish entirely (ammonia's
  # clean_content_tags). Fails if raw HTML ever renders as markup again.
  test "script tags render as nothing, never as markup" do
    html = Markdown.render("<script>alert(1)</script>")

    refute html =~ "<script"
    refute html =~ "alert"
    # Nothing hostile survived at all.
    refute html =~ "<"
  end

  # Event-handler attributes: the img onerror shape. The pin fires under
  # the combined regression (unsafe rendering plus the sanitize pass
  # dropped, the only way the tag survives verbatim) and under the
  # sanitize pass dropped alone (comrak's neutralization marker trips
  # the no-`<` refute). With comrak safe and ammonia on, ammonia's
  # rm_tags strips the img either way.
  test "an img with an event handler renders as nothing" do
    html = Markdown.render("<img src=x onerror=alert(1)>")

    refute html =~ "<img"
    refute html =~ "onerror"
    refute html =~ "<"
  end

  # Event-handler attributes on an allowed tag shape: the tag strips,
  # the text content stays inert.
  test "an inline tag with a handler strips the tag and keeps the text" do
    html = Markdown.render("<b onclick=\"alert(1)\">hi</b>")

    refute html =~ "onclick"
    refute html =~ "<b"
    assert html =~ "hi"
  end

  # javascript: scheme: comrak's safe render empties the href and the
  # ammonia pass confirms it — the link text stays as inert text.
  test "a javascript scheme link renders with an empty href" do
    html = Markdown.render("[click](javascript:alert(1))")

    refute html =~ "javascript:"
    assert html =~ "href=\"\""
    assert html =~ ">click</a>"
  end

  # data: scheme: the same inert treatment.
  test "a data scheme link renders with an empty href" do
    html = Markdown.render("[x](data:text/html;base64,PHNjcmlwdD4=)")

    refute html =~ "data:"
    assert html =~ "href=\"\""
    assert html =~ ">x</a>"
  end

  # Scheme detection is case-insensitive (JavaScript:, JAVASCRIPT:).
  test "a mixed-case scheme is inert too" do
    html =
      "[click](JavaScript:alert(1))"
      |> Markdown.render()
      |> String.downcase()

    refute html =~ "javascript:"
    assert html =~ "href=\"\""
  end

  # Raw HTML passthrough: block-level markup vanishes. Fails the moment
  # raw HTML renders as markup again.
  test "a raw HTML block renders as nothing" do
    html = Markdown.render("<div>raw block</div>")

    refute html =~ "<div"
    refute html =~ "<"
  end

  test "an iframe renders as nothing" do
    html = Markdown.render("<iframe src=\"https://evil.example\"></iframe>")

    refute html =~ "<iframe"
    refute html =~ "evil.example"
    refute html =~ "<"
  end

  # The scheme allowlist is OURS, not ammonia's default: tel: and ftp:
  # pass ammonia's defaults but not the issue's spec, so this pin fails
  # if the option falls back to the library default.
  test "off-spec schemes like tel and ftp lose their href" do
    html = Markdown.render("[call](tel:+15551234567) and [dl](ftp://example.com/f.tgz)")

    refute html =~ "tel:"
    refute html =~ "ftp:"
    assert html =~ ">call</a>"
    assert html =~ ">dl</a>"
  end

  # No images (reversible default): markdown image syntax strips. Fails
  # if rm_tags ever lifts the ban.
  test "markdown images render as nothing" do
    html = Markdown.render("![alt](https://example.com/pixel.png)")

    refute html =~ "<img"
    refute html =~ "pixel.png"
  end

  # rel="noopener noreferrer" rides every rendered link — the issue's
  # tabnabbing floor plus the referrer policy ammonia's default carries.
  # The pin fires when the whole sanitize pass drops (the rel vanishes)
  # or link_rel goes explicitly nil; dropping the explicit option alone
  # is invisible (it equals ammonia's default).
  test "rendered links carry rel noopener noreferrer" do
    html = Markdown.render("[site](https://example.com)")

    assert html =~ "rel=\"noopener noreferrer\""
    refute html =~ "target="
  end

  # --- Legacy plain-text bodies (backward compatibility) --------------------------

  # Single newlines hard-break: the pre-Markdown bodies (including the
  # seeded staging content) were written with real line breaks and must
  # not collapse into walls of text. Fails if hardbreaks drops.
  test "single newlines keep breaking" do
    assert Markdown.render("first line\nsecond line") ==
             "<p>first line<br>\nsecond line</p>"
  end

  test "a seeded-style multi-line body keeps every line" do
    body =
      "We run five instances across three apps.\nA first-class provider would let us\nmanage FluxVale like the rest of our stack."

    html = Markdown.render(body)

    assert html ==
             "<p>We run five instances across three apps.<br>\nA first-class provider would let us<br>\nmanage FluxVale like the rest of our stack.</p>"
  end

  test "blank lines still split paragraphs" do
    assert Markdown.render("para one\n\npara two") == "<p>para one</p>\n<p>para two</p>"
  end

  test "an empty body renders empty" do
    assert Markdown.render("") == ""
  end
end
