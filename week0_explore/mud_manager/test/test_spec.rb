require_relative "helper"

class TestSpec < Minitest::Test
  def test_every_tool_has_name_description_and_schema
    MudManager::Mcp::Spec.mcp_tools.each do |t|
      assert t["name"].is_a?(String) && !t["name"].empty?
      assert t["description"].is_a?(String) && !t["description"].empty?
      assert_equal "object", t["inputSchema"]["type"]
    end
  end

  def test_enums_are_pulled_live_from_primitives
    move = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "move" }
    assert_equal MudManager::Primitives::DIRECTIONS,
                 move["inputSchema"]["properties"]["direction"]["enum"]
  end

  def test_required_params_are_marked
    examine = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "examine" }
    assert_includes examine["inputSchema"]["required"], "target"

    # look has no required params, so the key is omitted entirely
    look = MudManager::Mcp::Spec.mcp_tools.find { |t| t["name"] == "look" }
    refute look["inputSchema"].key?("required")
  end

  def test_surface_matches_boukensha_tools
    # The gameplay surface boukensha used to implement in-process as Tools::Mud
    # (now deleted — boukensha owns no tools) must all live here instead, since
    # this daemon is the only implementation left. Connection tools stay hidden
    # behind the boundary on purpose.
    expected = %w[look examine check move flee set_position track attack
                  skill_strike consider say tell channel_say get_item drop_item
                  put_item equip_item consume_item cast_spell use_magic_item
                  shop practice save_character send_raw]
    names = MudManager::Mcp::Spec.mcp_tools.map { |t| t["name"] }
    expected.each { |n| assert_includes names, n, "missing tool #{n}" }
    # plus the daemon additions
    assert_includes names, "poll"
    assert_includes names, "mud_status"
  end

  def test_primitives_json_roundtrips
    json = MudManager::Mcp::Spec.primitives_json
    data = JSON.parse(json)
    assert_equal MudManager::VERSION, data["version"]
    assert data["tools"]["attack"]["args"]["style"]["enum"].include?("murder")
    assert_equal true, data["tools"]["examine"]["args"]["target"]["required"]
  end
end
