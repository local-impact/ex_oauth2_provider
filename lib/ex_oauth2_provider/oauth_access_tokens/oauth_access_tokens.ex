defmodule ExOauth2Provider.OauthAccessTokens do
  @moduledoc """
  Ecto schema for oauth access tokens
  """

  import Ecto.{Query, Changeset}, warn: false
  use ExOauth2Provider.Mixin.Expirable
  use ExOauth2Provider.Mixin.Revocable
  alias ExOauth2Provider.OauthAccessTokens.OauthAccessToken
  alias ExOauth2Provider.OauthApplications.OauthApplication

  @doc """
  Gets a single access token.

  Raises `Ecto.NoResultsError` if the OauthAccesstoken does not exist.

  ## Examples

      iex> get_token!("c341a5c7b331ef076eb4954668d54f590e0009e06b81b100191aa22c93044f3d")
      %OauthAccessGrant{}

      iex> get_token!("75d72f326a69444a9287ea264617058dbbfe754d7071b8eef8294cbf4e7e0fdc")
      ** (Ecto.NoResultsError)

  """
  def get_token(token) do
    ExOauth2Provider.repo.get_by(OauthAccessToken, token: token)
  end

  @doc """
  Gets the most recent access token.

  ## Examples

      iex> get_matching_token_for(user, app})
      %OauthAccessToken{}

      iex> get_matching_token_for(user, another_app})
      nil

  """
  def get_matching_token_for(%{id: resource_owner_id}, %OauthApplication{id: application_id}, scopes) do
    OauthAccessToken
    |> where([x], x.application_id == ^application_id)
    |> where([x], x.resource_owner_id == ^resource_owner_id)
    |> where([x], is_nil(x.revoked_at))
    |> order_by([x], desc: x.inserted_at)
    |> limit(1)
    |> ExOauth2Provider.repo.one
    |> check_matching_scopes(scopes)
  end

  @doc false
  defp check_matching_scopes(nil, _), do: nil
  defp check_matching_scopes(token, scopes) do
    token_scopes   = token.scopes |> ExOauth2Provider.Scopes.to_list
    request_scopes = scopes |> ExOauth2Provider.Scopes.to_list

    case ExOauth2Provider.Scopes.equal?(token_scopes, request_scopes) do
      true -> token
      _    -> nil
    end
  end

  @doc """
  Gets active tokens for resource owner.

  ## Examples

      iex> get_active_tokens_for(user)
      [%OauthAccessToken{}, ...]
  """
  def get_active_tokens_for(%{id: resource_owner_id}) do
    ExOauth2Provider.repo.all(from o in OauthAccessToken,
                              where: o.resource_owner_id == ^resource_owner_id and
                                     is_nil(o.revoked_at))
  end

  @doc """
  Creates an access token.

  ## Examples

      iex> create_token(user)
      {:ok, %OauthAccessGrant{}}

      iex> create_token(user)
      {:error, %Ecto.Changeset{}}

  """
  def create_token(%{id: _} = resource_owner, attrs \\ %{}) do
    %OauthAccessToken{resource_owner: resource_owner}
    |> new_token_changeset(attrs)
    |> ExOauth2Provider.repo.insert()
  end

  @doc """
  Finds existing access token or creates a new one.

  ## Examples

      iex> find_or_create_token(user)
      {:ok, %OauthAccessGrant{}}

      iex> find_or_create_token(user)
      {:error, %Ecto.Changeset{}}

  """
  def find_or_create_token(%{id: _} = resource_owner, attrs \\ %{}) do
    access_token = attrs
    |> Map.delete(:use_refresh_token)
    |> Map.merge(%{resource_owner_id: resource_owner.id})
    |> case do
      %{application: application} = attrs -> attrs
                                             |> Map.merge(%{application_id: application.id})
                                             |> Map.delete(:application)
      attrs -> attrs
    end
    |> Enum.reduce(OauthAccessToken, fn({k,v}, query) ->
      case v do
        nil -> where(query, [o], is_nil(field(o, ^k)))
        _   -> where(query, [o], field(o, ^k) == ^v)
      end
    end)
    |> limit(1)
    |> ExOauth2Provider.repo.one

    case is_accessible?(access_token) do
      true -> {:ok, access_token}
      false -> create_token(resource_owner, attrs)
    end
  end

  @doc """
  Checks if an access token can be accessed.

  ## Examples

      iex> is_accessible?(token)
      true

      iex> is_accessible?(inaccessible_token)
      false

  """
  def is_accessible?(%OauthAccessToken{} = token) do
    !is_expired?(token) and !is_revoked?(token)
  end
  def is_accessible?(nil), do: false

  defp new_token_changeset(%OauthAccessToken{} = token, params) do
    token
    |> cast(params, [:expires_in, :scopes])
    |> put_token
    |> put_refresh_token(params[:use_refresh_token])
    |> put_application(params)
    |> validate_application
    |> validate_required([:token, :resource_owner])
    |> assoc_constraint(:resource_owner)
    |> put_scopes
    |> unique_constraint(:token)
    |> unique_constraint(:refresh_token)
  end

  defp put_application(changeset, %{application: %OauthApplication{} = application}),
    do: put_assoc(changeset, :application, application)
  defp put_application(changeset, _), do: changeset

  defp validate_application(%{application: _} = changeset) do
    changeset
    |> assoc_constraint(:application)
  end
  defp validate_application(changeset), do: changeset

  defp put_token(%{} = changeset),
    do: change(changeset, %{token: ExOauth2Provider.Utils.generate_token})

  defp put_refresh_token(%{} = changeset, true),
    do: change(changeset, %{refresh_token: ExOauth2Provider.Utils.generate_token})
  defp put_refresh_token(%{} = changeset, _), do: changeset

  defp put_scopes(%{scopes: nil} = changeset),
    do: change(changeset, %{scopes: default_scopes_string()})
  defp put_scopes(changeset), do: changeset

  defp default_scopes_string do
    ExOauth2Provider.default_scopes
    |> ExOauth2Provider.Scopes.to_string
  end
end
