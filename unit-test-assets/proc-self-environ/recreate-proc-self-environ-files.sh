#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Note: Needs to be run on Linux. Use /start-injector-dev-container.sh if you are on a non-Linux system.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Note: Running with env -i to not leak private env vars into the resulting files.

# No relevant env var set:
env -i                                     cat /proc/self/environ > empty
env -i ENV_VAR_1=value_1 ENV_VAR_2=value_2 cat /proc/self/environ > environ-nothing-set

# Only OTEL_INJECTOR_LOG_LEVEL set:
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=debug ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-debug
env -i OTEL_INJECTOR_LOG_LEVEL=Info ENV_VAR_1=value_1 ENV_VAR_2=value_2             cat /proc/self/environ > environ-log-level-info
env -i ENV_VAR_1=value_1 ENV_VAR_2=value_2 OTEL_INJECTOR_LOG_LEVEL=WARN             cat /proc/self/environ > environ-log-level-warn
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=error ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-error
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=nOnE  ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-none
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=arbitrary-string ENV_VAR_2=value_2 cat /proc/self/environ > environ-log-level-arbitrary-string

# Only OTEL_INJECTOR_DISABLED set:
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_DISABLED=true ENV_VAR_2=value_2                 cat /proc/self/environ > environ-injector-disabled-true
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_DISABLED=false ENV_VAR_2=value_2                cat /proc/self/environ > environ-injector-disabled-false
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_DISABLED=1 ENV_VAR_2=value_2                    cat /proc/self/environ > environ-injector-disabled-1
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_DISABLED=arbitrary-string ENV_VAR_2=value_2     cat /proc/self/environ > environ-injector-disabled-arbitrary-string

# Both values set:
env -i \
  OTEL_INJECTOR_LOG_LEVEL=info \
  OTEL_INJECTOR_DISABLED=true \
  cat /proc/self/environ > environ-log-level-then-disabled
env -i \
  OTEL_INJECTOR_DISABLED=true \
  OTEL_INJECTOR_LOG_LEVEL=info \
  cat /proc/self/environ > environ-disabled-then-log-level

# Multiple relevant env vars set:
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=debug OTEL_INJECTOR_DISABLED=true ENV_VAR_2=value_2 cat /proc/self/environ > environ-log-level-debug

# A carefully constructed (albeit really contrived) test to make sure we handle overly long environment variables
# correctly in print.zig#initLogLevelFromEnvironFile.
env -i \
  VERY_LONG_ENV_VAR=ooobfpukjahymozzkhlgvnbfzblbyavesixpudbodfukxrxuohstkmtkszsffkgcuhyettbsotqcryxnbszxabtoumehnnpzkmfvhnqtrsqvgrgwkmyfzlmqzgwtqyrhmjorflxpfckhfrxbjyyuihjzfjliswdkonqlymawlqboaazfevmklitjaxqcigstvzarkcrqkcmmlsforhbacurdnpdezxzzbulexakrugskusexhtpvzksgcvizgyfwgmwmtlpkvvpjgtmxymxumwqyegzjflfbknowkgxfmuybznmnvitwqnrjokyojgzpvcpwfhgdwrsegnghwtmikycdkjvvbdgmlhsxbrkrhsldtcqybkxkbmclfbugtcrgsdwbcbyzfzcjgotykhrqutodftvzvwbuesylbvaexihdcwecttooafsiupwpkeinixldxjkeyciunacsxlkrsjdcbyojbiixzpesroulnamxbpqvbjpcarkxmssfdjtjcuqnsrjjkfbfgkrohfzawniwuzohepjrdryldtdjmieggoznzscbuestckasbglwqxajsaodmybkxjpknaubtejguxzsiasfqjpajbkrwhfemfnzlioalnynrnvgrxxfilhukzeweneoqycptqodehhtwqtmgxfapnvuhfoeznbpbyoxulutinjpuecfuembpsoichuykkddhebzskljrtwaeldnjpqjsptuzadzzagordbpmuukcdtzstjvmbyrunhkkbmbvbgvmsjguxunfiqegqpbihbxducnwqpcidnjdzfvyxzwvtalwuiixgwqnnguyfivbfaxdtdexhghgrtyomgxbihzduqdlvvortavvxgnhwxfbqjyhwoqnktatmisdqxqeakxdifxnqzyzcpymhinjatabqumdhmrhlwdrihpjrfeytbzahqcplyrukfwftjcgohjwhemyvwlwtrnsstazcuhjhsncycmmuydcenwhzagdsmrotyntushnokphxdgdxmurlyoikyizgcpvusdlbzlaiuxzaputvuaehnqaqsieohngzjzqfmjxvcxdinpmrvcgvwrbadhjemxjuflnpfdcprwrxjvnhorntlzkpgzqqwzcudtswcbifehjzwuhlcccmbdgiiombxaerdblooglgsycptaiawkrwfderlsiisukxhnphniaajboloonqkrwrbvmyrlrtcxpgdjkrfhhnndcthgsmtzwfpbtdsyccdtxnbfnguzbtsnzwyxivtoboxbdjrjqemtrpopzgokhazjuwyoxubvlhtzazgqijjfxijmnozavgrcxygyrvehqfzhuxrvvycepxsgjddassfsfhtnvzfnewzpbkbromggmtjslopfenkdqjqlkbwjgazbrszifosugnklvqymjtvmcmokefeutgkitnjyllfcekwugdqqmukkybnzcxlwbsuiuhuediovufletnlhelwedzkcktetidbjcgzeujzpklrjtrkkpzixhsbqhmtkuukxmujxgrjaijmkqnvtftpgzrpcdlabesrbsqanqbfyshocoxnlyqqsxgmzcprmnhgvubyptwcyxhihjpfpuklszumrhnzpkprucfzsuiipagaiogeaktbbneufnmvqjrhsnjjnehqzfnbjztcfigapdorqmpayodgxbajzyhxxrwdolpzcbkowivqyplfnawdrrjkunvgzbjinpxefsocugdckzwsaovboilvfowmihyocyyculwalqpmbzynqpcqayjtwbtxvjyrbvuicltgfjnrklppefofcprgmwtrgttqzjgkkgijgwivkszyawwkphhaooomsjjntjqshfdimxsmxxyhzalgwcfrhdznxrcpxbqghpecchetegibirnfblcgxlgfesopnivqnrcuhpkqrwmzprobinsxsshyimznypazhmzrhctiakkmskbysidunzfmtfpkcbuojbrzmyuhnfqzfiiOTEL_INJECTOR_LOG_LEVEL=debug \
  OTEL_INJECTOR_LOG_LEVEL=none \
  OTEL_INJECTOR_DISABLED=true \
  cat /proc/self/environ > overly-long-env-var
