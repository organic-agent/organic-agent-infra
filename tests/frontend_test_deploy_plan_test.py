#!/usr/bin/env python3
"""Check the saved deployment-bootstrap plan without printing state or secrets."""
import json
from pathlib import Path
import re
import sys

plan = json.loads(Path(sys.argv[1]).read_text())
changes = {
    change["address"]: change
    for change in plan.get("resource_changes", [])
    if change["mode"] == "managed" and change["change"]["actions"] != ["no-op"]
}
expected = {
    "module.frontend_test.aws_ssm_document.deploy",
    "module.github_actions.aws_iam_role.frontend_test_deploy",
    "module.github_actions.aws_iam_role_policy.frontend_test_deploy",
}
assert set(changes) == expected, f"Unexpected changed resource addresses: {set(changes) ^ expected}"
assert all(change["change"]["actions"] == ["create"] for change in changes.values()), "Only additions are allowed"

def after(address):
    return changes[address]["change"]["after"]

def as_set(value):
    return {value} if isinstance(value, str) else set(value)

role = after("module.github_actions.aws_iam_role.frontend_test_deploy")
trust = json.loads(role["assume_role_policy"])["Statement"]
assert len(trust) == 1
statement = trust[0]
assert statement["Effect"] == "Allow"
assert as_set(statement["Action"]) == {"sts:AssumeRoleWithWebIdentity"}
assert statement["Principal"] == {"Federated": "arn:aws:iam::233927217926:oidc-provider/token.actions.githubusercontent.com"}
assert statement["Condition"] == {"StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
    "token.actions.githubusercontent.com:sub": "repo:organic-agent@299031009/organic-agent-test-web@1359048612:ref:refs/heads/main",
    "token.actions.githubusercontent.com:repository_owner_id": "299031009",
    "token.actions.githubusercontent.com:repository_id": "1359048612",
    "token.actions.githubusercontent.com:ref": "refs/heads/main",
}}

policy = json.loads(after("module.github_actions.aws_iam_role_policy.frontend_test_deploy")["policy"])
permissions = {entry["Sid"]: (as_set(entry["Action"]), as_set(entry["Resource"])) for entry in policy["Statement"]}
assert permissions == {
    "UploadFrontendReleaseOnly": ({"s3:PutObject"}, {"arn:aws:s3:::wes-frontend-test-artifacts-233927217926/releases/*"}),
    "RunFixedFrontendDeploymentOnly": ({"ssm:SendCommand"}, {"arn:aws:ssm:ap-northeast-2:233927217926:document/wes-frontend-test-deploy"}),
    "TargetOnlyFrontendTestInstance": ({"ssm:SendCommand"}, {"arn:aws:ec2:ap-northeast-2:233927217926:instance/i-0ccbe2cc286bb9638"}),
    "PollDeploymentResult": ({"ssm:GetCommandInvocation"}, {"*"}),
}
assert all(entry["Effect"] == "Allow" for entry in policy["Statement"])

document = after("module.frontend_test.aws_ssm_document.deploy")
assert document["name"] == "wes-frontend-test-deploy"
content = json.loads(document["content"])
parameters = content["parameters"]
assert set(parameters) == {"ArtifactKey", "ArtifactSha256", "Revision"}
valid_values = {"ArtifactKey": "releases/" + "a" * 40 + ".tar.gz", "ArtifactSha256": "b" * 64, "Revision": "a" * 40}
for key, parameter in parameters.items():
    assert parameter["type"] == "String" and parameter["interpolationType"] == "ENV_VAR"
    assert re.fullmatch(parameter["allowedPattern"], valid_values[key])
    for unsafe in ("../other", "$(id)", "x; id", "a" * 40 + "\n", "releases/" + "a" * 40 + ".tar.gz;id"):
        assert re.fullmatch(parameter["allowedPattern"], unsafe) is None
command = content["mainSteps"][0]["inputs"]["runCommand"]
assert len(command) == 1
assert re.search(r"\{\{\s*(?:ArtifactKey|ArtifactSha256|Revision)\s*\}\}", command[0]) is None, "Inline SSM parameter interpolation is forbidden"
assert '[[ "$SSM_ArtifactKey" == "releases/$SSM_Revision.tar.gz" ]]' in command[0]
assert '/usr/local/bin/deploy-frontend "$SSM_ArtifactKey" "$SSM_ArtifactSha256" "$SSM_Revision"' in command[0]
print("Frontend Actions plan: 3 additions, no changes/deletions; exact OIDC, permissions, and SSM inputs verified.")
