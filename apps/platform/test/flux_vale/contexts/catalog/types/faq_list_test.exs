defmodule FluxVale.Catalog.Types.FaqListTest do
  @moduledoc false

  # The FAQ list type (#611) — casting and validation semantics live
  # here, mirroring ScreenshotListTest's shape.

  use ExUnit.Case, async: true

  alias FluxVale.Catalog.Types.FaqList

  @valid [
    %{
      "question" => "Does it work without my own server?",
      "answer" => "Yes. FluxVale runs it on managed Kubernetes for you."
    },
    %{
      "question" => "Can I move my data out again?",
      "answer" => "Yes. The volume is yours, and backups rest in your own bucket."
    }
  ]

  # The shape every single-item test builds from.
  @first Enum.at(@valid, 0)

  describe "new/1" do
    test "casts string-keyed items (YAML/JSON/Admin form shape)" do
      assert {:ok, faq} = FaqList.new(@valid)

      assert faq == [
               %{
                 question: "Does it work without my own server?",
                 answer: "Yes. FluxVale runs it on managed Kubernetes for you."
               },
               %{
                 question: "Can I move my data out again?",
                 answer: "Yes. The volume is yours, and backups rest in your own bucket."
               }
             ]
    end

    test "accepts atom keys" do
      assert {:ok, [item]} =
               FaqList.new([
                 %{question: "Is SSH available?", answer: "No. Git works over HTTPS only."}
               ])

      assert item.question == "Is SSH available?"
    end

    test "accepts between one and four items" do
      four = @valid ++ @valid
      assert {:ok, items} = FaqList.new(four)
      assert length(items) == 4
    end

    test "rejects five items" do
      five = @valid ++ @valid ++ [Enum.at(@valid, 1)]

      assert {:error, message} = FaqList.new(five)
      assert message == "expected 1-4 FAQ items, got 5"
    end

    test "rejects unknown fields — a typo'd item fails loudly" do
      typo = [Map.put(@first, "queston", "Does it work?")]

      assert {:error, message} = FaqList.new(typo)

      assert message ==
               ~s|unknown field(s) ["queston"]; supported: [:answer, :question]|
    end

    test "bounds question to 8-120 chars, answer to 20-600 chars" do
      short_question = %{@first | "question" => "Works?"}
      assert {:error, message} = FaqList.new([short_question])
      assert message == "question must be 8-120 characters, got 6"

      long_question = %{@first | "question" => String.duplicate("q", 121)}
      assert {:error, message} = FaqList.new([long_question])
      assert message == "question must be 8-120 characters, got 121"

      assert {:error, message} = FaqList.new([Map.delete(@first, "question")])
      assert message == "question is required"

      assert {:error, message} = FaqList.new([%{@first | "question" => 5}])
      assert message == "question must be a string, got: 5"

      short_answer = %{@first | "answer" => "too short, sorry"}
      assert {:error, message} = FaqList.new([short_answer])
      assert message == "answer must be 20-600 characters, got 16"

      long_answer = %{@first | "answer" => String.duplicate("a", 601)}
      assert {:error, message} = FaqList.new([long_answer])
      assert message == "answer must be 20-600 characters, got 601"

      assert {:error, message} = FaqList.new([Map.delete(@first, "answer")])
      assert message == "answer is required"

      assert {:error, message} = FaqList.new([%{@first | "answer" => []}])
      assert message == "answer must be a string, got: []"
    end

    test "requires the question to end with a question mark" do
      statement = %{@first | "question" => "How to set the app up"}

      assert {:error, message} = FaqList.new([statement])
      assert message == ~s(question must end with a question mark, got: "How to set the app up")
    end

    test "rejects em dashes and semicolons in both fields (D10)" do
      em_dash = %{@first | "question" => "Does it work — really?"}

      assert {:error, message} = FaqList.new([em_dash])
      assert message == "question must not contain an em dash. Use short plain sentences."

      semicolon = %{@first | "answer" => "Yes; it works without one of those."}

      assert {:error, message} = FaqList.new([semicolon])
      assert message == "answer must not contain a semicolon. Use short plain sentences."
    end

    test "rejects non-map items and non-list input" do
      assert {:error, message} = FaqList.new(["Does it work?"])
      assert message =~ "each FAQ item must be a map"

      assert {:error, message} = FaqList.new(@first)
      assert message == "expected a list of FAQ items"
    end

    test "rejects malformed key shapes" do
      assert {:error, message} = FaqList.new([Map.put(@first, 1, "x")])
      assert message =~ "FAQ item keys must be strings or atoms"
    end
  end

  describe "cast_input/2, dump_to_native/2, and cast_stored/2" do
    test "nil is the absent state — [] in and out of storage" do
      assert {:ok, []} = FaqList.cast_input(nil, [])
      assert {:ok, []} = FaqList.dump_to_native(nil, [])
      assert {:ok, []} = FaqList.cast_stored(nil, [])
    end

    test "cast_input surfaces the cast error for a malformed list" do
      assert {:error, message} = FaqList.cast_input([%{"question" => "No answer given?"}], [])
      assert message =~ "answer is required"

      assert {:error, message} = FaqList.cast_input("nope", [])
      assert message == "expected a list of FAQ items"
    end

    test "dumps to string-keyed maps and re-casts on read (jsonb round-trip)" do
      {:ok, faq} = FaqList.new(@valid)

      assert {:ok, dumped} = FaqList.dump_to_native(faq, [])

      assert dumped == [
               %{
                 "question" => "Does it work without my own server?",
                 "answer" => "Yes. FluxVale runs it on managed Kubernetes for you."
               },
               %{
                 "question" => "Can I move my data out again?",
                 "answer" => "Yes. The volume is yours, and backups rest in your own bucket."
               }
             ]

      assert {:ok, ^faq} = FaqList.cast_stored(dumped, [])
    end

    test "the defensive dump/stored arms reject non-lists" do
      assert {:error, message} = FaqList.dump_to_native("nope", [])
      assert message == "expected a list of FAQ items"

      assert {:error, message} = FaqList.cast_stored("nope", [])
      assert message == "expected a list of FAQ items"
    end
  end
end
