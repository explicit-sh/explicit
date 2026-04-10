defmodule Explicit.Sarif do
  @moduledoc """
  Generate SARIF v2.1.0 (Static Analysis Results Interchange Format) output.
  Compatible with GitHub Code Scanning, VS Code SARIF Viewer, and CI/CD tools.
  """

  @sarif_version "2.1.0"
  @schema "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json"

  @doc "Generate SARIF JSON from violations and doc diagnostics"
  @spec generate(String.t()) :: map()
  def generate(project_dir) do
    code_violations = Explicit.ViolationStore.all()
    |> Enum.flat_map(fn {path, vs} -> Enum.map(vs, &Map.put(&1, :file, path)) end)

    doc_diagnostics = Explicit.DocStore.all()
    |> Enum.flat_map(fn {path, ds} ->
      Enum.map(ds, fn {level, code, msg} ->
        %{file: path, line: 0, check: code, message: msg, level: level}
      end)
    end)

    all_results = code_violations ++ doc_diagnostics

    %{
      "$schema" => @schema,
      "version" => @sarif_version,
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{
              "name" => "explicit",
              "version" => "0.3.15",
              "informationUri" => "https://github.com/explicit-sh/explicit",
              "rules" => build_rules(all_results)
            }
          },
          "results" => build_results(all_results, project_dir),
          "invocations" => [
            %{
              "executionSuccessful" => true,
              "workingDirectory" => %{"uri" => "file://#{project_dir}"}
            }
          ]
        }
      ]
    }
  end

  defp build_rules(results) do
    results
    |> Enum.map(& &1.check)
    |> Enum.uniq()
    |> Enum.map(fn rule_id ->
      %{
        "id" => rule_id,
        "shortDescription" => %{"text" => rule_id},
        "defaultConfiguration" => %{"level" => "warning"}
      }
    end)
  end

  defp build_results(results, project_dir) do
    Enum.map(results, fn r ->
      rel_path = Path.relative_to(r.file, project_dir)
      line = Map.get(r, :line, 0)

      level = case Map.get(r, :level) do
        :error -> "error"
        :warning -> "warning"
        _ -> "warning"
      end

      %{
        "ruleId" => r.check,
        "level" => level,
        "message" => %{"text" => r.message},
        "locations" => [
          %{
            "physicalLocation" => %{
              "artifactLocation" => %{
                "uri" => rel_path,
                "uriBaseId" => "%SRCROOT%"
              },
              "region" => %{
                "startLine" => max(line, 1)
              }
            }
          }
        ]
      }
    end)
  end
end
