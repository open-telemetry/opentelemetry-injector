#!/usr/bin/env bash

# Copyright The OpenTelemetry Authors
# SPDX-License-Identifier: Apache-2.0

# Note: Needs to be run on Linux. Use /start-injector-dev-container.sh if you are on a non-Linux system.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

# Note: Running with env -i to not leak private env vars into the resulting files.
env -i ENV_VAR_1=value_1 ENV_VAR_2=value_2                                          cat /proc/self/environ > environ-no-log-level
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=debug ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-debug
env -i OTEL_INJECTOR_LOG_LEVEL=Info ENV_VAR_1=value_1 ENV_VAR_2=value_2             cat /proc/self/environ > environ-log-level-info
env -i ENV_VAR_1=value_1 ENV_VAR_2=value_2 OTEL_INJECTOR_LOG_LEVEL=WARN             cat /proc/self/environ > environ-log-level-warn
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=error ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-error
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=nOnE  ENV_VAR_2=value_2            cat /proc/self/environ > environ-log-level-none
env -i ENV_VAR_1=value_1 OTEL_INJECTOR_LOG_LEVEL=arbitrary-string ENV_VAR_2=value_2 cat /proc/self/environ > environ-log-level-arbitrary-string

# A carefully constructed (albeit really contrived) test to make sure we handle overly long environment variables
# correctly in print.zig#initLogLevelFromEnvironFile.
env -i \
  VERY_LONG_ENV_VAR=ooobfpukjahymozzkhlgvnbfzblbyavesixpudbodfukxrxuohstkmtkszsffkgcuhyettbsotqcryxnbszxabtoumehnnpzkmfvhnqtrsqvgrgwkmyfzlmqzgwtqyrhmjorflxpfckhfrxbjyyuihjzfjliswdkonqlymawlqboaazfevmklitjaxqcigstvzarkcrqkcmmlsforhbacurdnpdezxzzbulexakrugskusexhtpvzksgcvizgyfwgmwmtlpkvvpjgtmxymxumwqyegzjflfbknowkgxfmuybznmnvitwqnrjokyojgzpvcpwfhgdwrsegnghwtmikycdkjvvbdgmlhsxbrkrhsldtcqybkxkbmclfbugtcrgsdwbcbyzfzcjgotykhrqutodftvzvwbuesylbvaexihdcwecttooafsiupwpkeinixldxjkeyciunacsxlkrsjdcbyojbiixzpesroulnamxbpqvbjpcarkxmssfdjtjcuqnsrjjkfbfgkrohfzawniwuzohepjrdryldtdjmieggoznzscbuestckasbglwqxajsaodmybkxjpknaubtejguxzsiasfqjpajbkrwhfemfnzlioalnynrnvgrxxfilhukzeweneoqycptqodehhtwqtmgxfapnvuhfoeznbpbyoxulutinjpuecfuembpsoichuykkddhebzskljrtwaeldnjpqjsptuzadzzagordbpmuukcdtzstjvmbyrunhkkbmbvbgvmsjguxunfiqegqpbihbxducnwqpcidnjdzfvyxzwvtalwuiixgwqnnguyfivbfaxdtdexhghgrtyomgxbihzduqdlvvortavvxgnhwxfbqjyhwoqnktatmisdqxqeakxdifxnqzyzcpymhinjatabqumdhmrhlwdrihpjrfeytbzahqcplyrukfwftjcgohjwhemyvwlwtrnsstazcuhjhsncycmmuydcenwhzagdsmrotyntushnokphxdgdxmurlyoikyizgcpvusdlbzlaiuxzaputvuaehnqaqsieohngzjzqfmjxvcxdinpmrvcgvwrbadhjemxjuflnpfdcprwrxjvnhorntlzkpgzqqwzcudtswcbifehjzwuhlcccmbdgiiombxaerdblooglgsycptaiawkrwfderlsiisukxhnphniaajboloonqkrwrbvmyrlrtcxpgdjkrfhhnndcthgsmtzwfpbtdsyccdtxnbfnguzbtsnzwyxivtoboxbdjrjqemtrpopzgokhazjuwyoxubvlhtzazgqijjfxijmnozavgrcxygyrvehqfzhuxrvvycepxsgjddassfsfhtnvzfnewzpbkbromggmtjslopfenkdqjqlkbwjgazbrszifosugnklvqymjtvmcmokefeutgkitnjyllfcekwugdqqmukkybnzcxlwbsuiuhuediovufletnlhelwedzkcktetidbjcgzeujzpklrjtrkkpzixhsbqhmtkuukxmujxgrjaijmkqnvtftpgzrpcdlabesrbsqanqbfyshocoxnlyqqsxgmzcprmnhgvubyptwcyxhihjpfpuklszumrhnzpkprucfzsuiipagaiogeaktbbneufnmvqjrhsnjjnehqzfnbjztcfigapdorqmpayodgxbajzyhxxrwdolpzcbkowivqyplfnawdrrjkunvgzbjinpxefsocugdckzwsaovboilvfowmihyocyyculwalqpmbzynqpcqayjtwbtxvjyrbvuicltgfjnrklppefofcprgmwtrgttqzjgkkgijgwivkszyawwkphhaooomsjjntjqshfdimxsmxxyhzalgwcfrhdznxrcpxbqghpecchetegibirnfblcgxlgfesopnivqnrcuhpkqrwmzprobinsxsshyimznypazhmzrhctiakkmskbysidunzfmtfpkcbuojbrzmyuhnfqzfiiOTEL_INJECTOR_LOG_LEVEL=debug \
  OTEL_INJECTOR_LOG_LEVEL=none \
  cat /proc/self/environ > log-level-none-overly-long-env-var

