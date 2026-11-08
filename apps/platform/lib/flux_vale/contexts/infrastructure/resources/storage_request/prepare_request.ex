defmodule FluxVale.Infrastructure.StorageRequest.PrepareRequest do
  @moduledoc """
  The `:request` create's preparation (#250, ADR-0046 §4): loads the
  target instance through the **authorized** read (a stranger's id is
  a not-found, never a queue row), snapshots the org and the current
  allocation, quotes through `ResizePreview` at the target and at the
  current allocation, and runs the boundary validations.

  The quote is advisory (D7): approval re-prices at the rates in force
  then. An unpriced version — or a pricing read that failed — quotes
  nil rather than blocking the request on a number the member copy
  never promises anyway.

  Creating a request is free: the wallet gate (the resize's #124 gate)
  bites at approval, where the operator decides whether to procure.
  """

  use Ash.Resource.Change

  alias FluxVale.Infrastructure.Instance
  alias FluxVale.Infrastructure.Operations.ResizePreview
  alias FluxVale.Infrastructure.StorageRequest

  require Ash.Query

  @config_key :storage_beyond_threshold

  @impl Ash.Resource.Change
  def change(changeset, _opts, context) do
    instance_id = Ash.Changeset.get_argument(changeset, :instance_id)

    case Instance.get_by_id(instance_id, actor: context.actor, authorize?: context.authorize?) do
      {:ok, instance} ->
        prepare(changeset, instance, context.actor)

      # The policy is the real gate; this arm gives a member's own
      # typo/missing id a plain answer instead of a crash.
      {:error, _error} ->
        Ash.Changeset.add_error(changeset, "instance not found")
    end
  end

  defp prepare(changeset, instance, actor) do
    requested = Ash.Changeset.get_attribute(changeset, :requested_gb)
    config = Application.fetch_env!(:flux_vale, @config_key)

    prepared =
      changeset
      |> Ash.Changeset.force_change_attribute(:instance_id, instance.id)
      |> Ash.Changeset.force_change_attribute(:organization_id, instance.organization_id)
      |> Ash.Changeset.force_change_attribute(:current_storage_gb, instance.storage_gb)
      |> put_requester(actor)
      |> put_quotes(instance, requested)

    validate_request(prepared, instance, requested, config)
  end

  # A create without an actor (a bootstrap path) leaves the attribute
  # nil for the required validation to answer — never a guessed owner.
  defp put_requester(changeset, %{id: id}) do
    Ash.Changeset.force_change_attribute(changeset, :requested_by_user_id, id)
  end

  defp put_requester(changeset, _actor), do: changeset

  defp put_quotes(changeset, _instance, nil), do: changeset

  defp put_quotes(changeset, instance, requested) do
    target = monthly_quote(instance, requested)
    current = monthly_quote(instance, instance.storage_gb)

    changeset
    |> Ash.Changeset.force_change_attribute(:quoted_monthly_cents, target)
    |> Ash.Changeset.force_change_attribute(:quoted_current_cents, current)
  end

  # The running monthly figure — the one the member compares. Unpriced
  # and failed pricing reads both answer nil (advisory).
  defp monthly_quote(instance, storage_gb) do
    allocation = %{
      cpu_cores: instance.cpu_cores,
      memory_mb: instance.memory_mb,
      storage_gb: storage_gb
    }

    case ResizePreview.call(instance, allocation) do
      {:ok, %{running_cents: cents}} -> cents
      {:ok, nil} -> nil
      {:error, _reason} -> nil
    end
  end

  defp validate_request(changeset, instance, requested, config) when is_integer(requested) do
    changeset
    |> validate_above_current(instance, requested)
    |> validate_above_threshold(requested, config)
    |> validate_below_max(requested, config)
    |> validate_no_open_request(instance)
    |> validate_instance_live(instance)
  end

  # A nil/mistyped target is the attribute's own required/type error —
  # the boundary checks would only add noise.
  defp validate_request(changeset, _instance, _requested, _config), do: changeset

  defp validate_above_current(changeset, instance, requested) do
    if requested > instance.storage_gb do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        "requested storage must be above the current #{instance.storage_gb} GB"
      )
    end
  end

  defp validate_above_threshold(changeset, requested, config) do
    %{threshold_gb: threshold} = config

    if requested > threshold do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        "self-service storage covers up to #{threshold} GB — resize instead"
      )
    end
  end

  defp validate_below_max(changeset, requested, config) do
    %{max_gb: max_gb} = config

    if requested <= max_gb do
      changeset
    else
      Ash.Changeset.add_error(
        changeset,
        "requested storage exceeds the #{max_gb} GB maximum"
      )
    end
  end

  # The advisory half of the one-open-request invariant; the partial
  # unique index is the atomic half (a racing submit loses its insert
  # with a DB error, never a duplicate queue row).
  defp validate_no_open_request(changeset, instance) do
    if open_request?(instance.id) do
      Ash.Changeset.add_error(
        changeset,
        "this instance already has an open storage request"
      )
    else
      changeset
    end
  end

  defp open_request?(instance_id) do
    StorageRequest
    |> Ash.Query.filter(instance_id == ^instance_id and status in [:requested, :approved])
    |> Ash.Query.limit(1)
    |> Ash.exists?(authorize?: false)
  end

  defp validate_instance_live(changeset, instance) do
    if instance.status in [:deleting, :lost] do
      Ash.Changeset.add_error(
        changeset,
        "cannot request storage for an instance in #{instance.status} state"
      )
    else
      changeset
    end
  end

  @impl Ash.Resource.Change
  # coveralls-ignore-next-line trivial callback — always false (reads another table)
  def atomic?, do: false
end
