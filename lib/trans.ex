defmodule Trans do
  @moduledoc """
  Manage translations embedded into structs.

  Although it can be used with any struct **`Trans` shines when paired with an `Ecto.Schema`**. It
  allows you to keep the translations into a field of the schema and avoids requiring extra tables
  for translation storage and complex _joins_ when retrieving translations from the database.

  `Trans` is split into two main components:

  * `Trans.Translator` - provides easy access to struct translations.
  * `Trans.QueryBuilder` - provides helpers for querying translations using `Ecto.Query`
    (requires `Ecto.SQL`).

  When used, `Trans` accepts the following options:

  * `:translates` (required) - list of the fields that will be translated.
  * `:container` (optional) - name of the field that contains the embedded translations.
    Defaults to`:translations`.
  * `:default_locale` (optional) - declares the locale of the base untranslated column.

  ## Structured translations

  Structured translations are the preferred and recommended way of using `Trans`. To use structured
  translations **you must define the translations as embedded schemas**:

      defmodule MyApp.Article do
        use Ecto.Schema
        use Trans, translates: [:title, :body], default_locale: :en

        schema "articles" do
          field :title, :string
          field :body, :string

          embeds_one :translations, Translations, on_replace: :update, primary_key: false do
            embeds_one :es, MyApp.Article.Translation
            embeds_one :fr, MyApp.Article.Translation
          end
        end
      end

      defmodule MyApp.Article.Translation do
        use Ecto.Schema

        @primary_key false
        embedded_schema do
          field :title, :string
          field :body, :string
        end
      end

  Although they required more code than free-form translations, **structured translations provide
  some nice benefits** that make them the preferred way of using `Trans`:

  * High flexibility when making validations and transformation using the embedded schema's own
    changeset.
  * Easy to integrate with HTML forms leveraging the capabilities of `inputs_for`
  * Easy navegability using the dot notation.

  ## Free-form translations

  Free-form translations were the main way of using `Trans` until the 2.3.0 version. They are still
  supported for compatibility with older versions but not recommended for new projects.

  To use free-form translations you must define the translations as a map:

      defmodule MyApp.Article do
        use Ecto.Schema
        use Trans, translates: [:title, :body], default_locale: :en

        schema "articles" do
          field :title, :string
          field :body, :string
          field :translations, :map
        end
      end

  Although they require less code, **free-form translations  provide much less guarantees**:

  * There is no way to tell what content and wich form will be stored in the translations field.
  * Hard to integrate with HTML forms since the Phoenix helpers are not available.
  * Difficult navigation requiring the braces notation from the `Access` protocol.

  ## The translation container

  As we have seen in the previous examples, `Trans` automatically stores and looks for translations
  in a field called `:translations`. This is known as the **translations container.**

  In certain cases you may want to use a different field for storing the translations, this can
  be specified when using `Trans` in your module.

      # Use the field `:locales` as translation container instead of the default `:translations`
      use Trans, translates: [...], container: :locales

  ## Reflection

  Any module that uses `Trans` will have an autogenerated `__trans__` function that can be used for
  runtime introspection of the translation metadata.

  * `__trans__(:fields)` - Returns the list of translatable fields.
  * `__trans__(:container)` - Returns the name of the translation container.
  * `__trans__(:default_locale)` - Returns the name of default locale.
  """

  @typedoc """
  A translatable struct that uses `Trans`
  """
  @type translatable() :: struct()

  @typedoc """
  A locale that may be a string or an atom
  """
  @type locale() :: String.t() | atom()

  @typedoc """
  When translating or querying either a single
  locale or a list of locales can be provided
  """
  @type locale_list :: locale | [locale, ...]

  defmacro __using__(opts) do
    quote do
      Module.put_attribute(__MODULE__, :trans_fields, unquote(translatable_fields(opts)))
      Module.put_attribute(__MODULE__, :trans_container, unquote(translation_container(opts)))

      Module.put_attribute(
        __MODULE__,
        :trans_default_locale,
        unquote(translation_default_locale(opts))
      )

      import Trans, only: :macros

      @after_compile {Trans, :__validate_translatable_fields__}
      @after_compile {Trans, :__validate_translation_container__}

      @spec __trans__(:fields) :: list(atom)
      def __trans__(:fields), do: @trans_fields

      @spec __trans__(:container) :: atom
      def __trans__(:container), do: @trans_container

      @spec __trans__(:default_locale) :: atom
      def __trans__(:default_locale), do: @trans_default_locale
    end
  end

  @doc false
  def default_trans_options do
    [on_replace: :update, primary_key: false, build_field_schema: true]
  end

  defmacro translations(field_name, translation_module, locales, options \\ []) do
    options = Keyword.merge(Trans.default_trans_options(), options)
    {build_field_schema, options} = Keyword.pop(options, :build_field_schema)

    quote do
      if unquote(translation_module) && unquote(build_field_schema) do
        @before_compile {Trans, :__build_embedded_schema__}
      end

      @translation_module Module.concat(__MODULE__, unquote(translation_module))

      embeds_one unquote(field_name), unquote(translation_module), unquote(options) do
        for locale_name <- List.wrap(unquote(locales)) do
          embeds_one locale_name, unquote(translation_module).Fields, on_replace: :update
        end
      end
    end
  end

  defmacro __build_embedded_schema__(env) do
    translation_module = Module.get_attribute(env.module, :translation_module)
    fields = Module.get_attribute(env.module, :trans_fields)

    quote do
      defmodule Module.concat(unquote(translation_module), :Fields) do
        use Ecto.Schema
        import Ecto.Changeset

        @primary_key false
        embedded_schema do
          for a_field <- unquote(fields) do
            field a_field, :string
          end
        end

        def changeset(fields, params) do
          fields
          |> cast(params, unquote(fields))
          |> validate_required(unquote(fields))
        end
      end
    end
  end

  @doc """
  Checks whether the given field is translatable or not.

  Returns true if the given field is translatable. Raises if the given module or struct does not use
  `Trans`.

  ## Examples

  Assuming the Article schema defined in [Structured translations](#module-structued-translations).

  If we want to know whether a certain field is translatable or not we can use
  this function as follows (we can also pass a struct instead of the module
  name itself):

      iex> Trans.translatable?(Article, :title)
      true

  May be also used with translatable structs:

      iex> article = %Article{}
      iex> Trans.translatable?(article, :not_existing)
      false

  Raises if the given module or struct does not use `Trans`:

      iex> Trans.translatable?(Date, :day)
      ** (RuntimeError) Elixir.Date must use `Trans` in order to be translated
  """
  def translatable?(module_or_translatable, field)

  @spec translatable?(module | translatable(), String.t() | atom) :: boolean
  def translatable?(%{__struct__: module}, field), do: translatable?(module, field)

  def translatable?(module, field) when is_atom(module) and is_binary(field) do
    translatable?(module, String.to_atom(field))
  end

  def translatable?(module, field) when is_atom(module) and is_atom(field) do
    if Keyword.has_key?(module.__info__(:functions), :__trans__) do
      Enum.member?(module.__trans__(:fields), field)
    else
      raise "#{module} must use `Trans` in order to be translated"
    end
  end

  @doc false
  def __validate_translatable_fields__(%{module: module}, _bytecode) do
    struct_fields =
      module.__struct__()
      |> Map.keys()
      |> MapSet.new()

    translatable_fields =
      :fields
      |> module.__trans__
      |> MapSet.new()

    invalid_fields = MapSet.difference(translatable_fields, struct_fields)

    case MapSet.size(invalid_fields) do
      0 ->
        nil

      1 ->
        raise ArgumentError,
          message:
            "#{module} declares '#{MapSet.to_list(invalid_fields)}' as translatable but it is not defined in the module's struct"

      _ ->
        raise ArgumentError,
          message:
            "#{module} declares '#{MapSet.to_list(invalid_fields)}' as translatable but it they not defined in the module's struct"
    end
  end

  @doc false
  def __validate_translation_container__(%{module: module}, _bytecode) do
    container = module.__trans__(:container)

    unless Enum.member?(Map.keys(module.__struct__()), container) do
      raise ArgumentError,
        message:
          "The field #{container} used as the translation container is not defined in #{module} struct"
    end
  end

  defp translatable_fields(opts) do
    case Keyword.fetch(opts, :translates) do
      {:ok, fields} when is_list(fields) ->
        fields

      _ ->
        raise ArgumentError,
          message:
            "Trans requires a 'translates' option that contains the list of translatable fields names"
    end
  end

  defp translation_container(opts) do
    case Keyword.fetch(opts, :container) do
      :error -> :translations
      {:ok, container} -> container
    end
  end

  defp translation_default_locale(opts) do
    case Keyword.fetch(opts, :default_locale) do
      :error -> nil
      {:ok, default_locale} -> default_locale
    end
  end
end
