write-host -for white "I'm checking all ps1 files in:"
write-host -for cyan "     $((pwd).path)"
$errors = Invoke-ScriptAnalyzer -Path .\ -Severity Error|?{$_.RuleName -ne 'PSAvoidUsingConvertToSecureStringWithPlainText'}
if ($errors) {
  write-host -for red "Found erros:"
  $errors
} else {
  write-host -for green 'GOOD no errors (excluding PSAvoidUsingConvertToSecureStringWithPlainText)'
}