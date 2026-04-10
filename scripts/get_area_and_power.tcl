puts "set_db design_process_node 130"
set_db design_process_node 130

puts "set_multi_cpu_usage -local_cpu 4"
set_multi_cpu_usage -local_cpu 4

# Use a post-route checkpoint
read_db post_write_design

report_area
report_power

exit
