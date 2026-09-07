defmodule FluxVale.Ops do
  @moduledoc """
  Ops: operator-facing resources — platform-wide effect, operator-only
  mutation, invisible to customers (ADR-0030). `FeatureFlag` lands with #25;
  `AccessRule` follows (#26). The designated growth home for future operator
  resources (audit entries, maintenance windows, announcements).

  Opts into AshAdmin (ADR-0027): mutations ride the platform-admin policy —
  the dashboard adds no new authorization model.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show? true
  end

  resources do
    resource FluxVale.Ops.FeatureFlag
  end
end
