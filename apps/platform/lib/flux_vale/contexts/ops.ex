defmodule FluxVale.Ops do
  @moduledoc """
  Ops: operator-facing resources — platform-wide effect, operator-only
  mutation, invisible to customers (ADR-0030). `FeatureFlag` landed with #25;
  `AccessRule` with #26; `InvitedEmail` with #478. The designated growth
  home for future operator resources (audit entries, maintenance
  windows, announcements).

  Opts into AshAdmin (ADR-0027): mutations ride the platform-admin policy —
  the dashboard adds no new authorization model.
  """

  use Ash.Domain,
    otp_app: :flux_vale,
    extensions: [AshAdmin.Domain]

  admin do
    show?(true)
  end

  resources do
    resource(FluxVale.Ops.FeatureFlag)
    resource(FluxVale.Ops.AccessRule)
    # #478: the early-access invitations — AshAdmin manages them (list,
    # add (which IS the invite, the email rides the create), revoke);
    # the identity layer consults them through Ops.InvitedEmails.
    resource(FluxVale.Ops.InvitedEmail)
  end
end
