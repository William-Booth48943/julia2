module Artifacts
using Pkg.Artifacts
export artifact_exists, artifact_path, artifact_meta, artifact_hash,
       find_artifacts_toml, @artifact_str
end
