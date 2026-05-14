package vkh
import "../../modules/vma"
import "core:fmt"
import "core:mem"
import os "core:os"
import "core:path/filepath"
import "core:strings"
import c "vendor:cgltf"
import stbImage "vendor:stb/image"
import vk "vendor:vulkan"

GltfVertex :: struct {
	pos:  [3]f32,
	uv:   [2]f32,
	norm: [3]f32,
}


// GltfPrimitive :: struct {
// 	// vertices:        [dynamic]GltfVertex,
// 	// indices:         [dynamic]u32,
// 	image:           GltfPrimitiveImage,
// 	type:            c.primitive_type,
// 	baseColorFactor: [4]f32,
// }
GLTF_INDICES_TYPE_USED :: u32
@(require_results)
read_gltf_model :: proc(path: string, cb: vk.CommandBuffer) -> (model: Model) // primitives: [dynamic]^Primitive,
{
	assert(os.exists(path))
	options := c.options {
		type = .invalid,
	}

	assert(os.exists(path))
	cFilePath := strings.clone_to_cstring(path, context.temp_allocator)
	data, res := c.parse_file(options, cFilePath)
	assert(res == .success)
	defer c.free(data)

	bufferRes := c.load_buffers(options, data, cFilePath)
	assert(bufferRes == .success)

	when ODIN_DEBUG {
		validationRes := c.validate(data)
		assert(validationRes == .success)
	}

	assert(len(data.scenes) > 0)
	defaultScene := data.scenes[0]
	for node in defaultScene.nodes {
		if node.mesh == nil do continue

		mesh := node.mesh
		localMat: matrix[4, 4]f32

		if node.has_matrix {
			mem.copy(&localMat, &node.matrix_, size_of(localMat))
		} else {
			flat: [16]f32
			c.node_transform_local(node, raw_data(flat[:]))
			localMat = transmute(matrix[4, 4]f32)flat
		}

		for primitive in mesh.primitives {

			primInfoImage := ImageLoaderInputs{}


			// positions := make([dynamic][3]f32, context.temp_allocator)
			// normals := make([dynamic][3]f32, context.temp_allocator)
			// uvs := make([dynamic][2]f32, context.temp_allocator)


			// for attrib in primitive.attributes {
			// 	accessor := attrib.data
			// 	#partial switch attrib.type {
			// 	case .position:
			// 		num_components := c.num_components(accessor.type)
			// 		numFloats := accessor.count * num_components
			// 		resize(&positions, accessor.count)
			// 		floats_read := c.accessor_unpack_floats(
			// 			accessor,
			// 			transmute([^]f32)raw_data(positions),
			// 			numFloats,
			// 		)
			// 		assert(floats_read == numFloats)
			// 	case .normal:
			// 		numComponents := c.num_components(accessor.type)
			// 		numNormals := accessor.count * numComponents
			// 		resize(&normals, accessor.count)
			// 		normalsRead := c.accessor_unpack_floats(
			// 			attrib.data,
			// 			transmute([^]f32)raw_data(normals),
			// 			numNormals,
			// 		)
			// 		assert(normalsRead == numNormals)
			// 	case .texcoord:
			// 		numComponents := c.num_components(accessor.type)
			// 		numFloats := accessor.count * numComponents
			// 		resize(&uvs, accessor.count)

			// 		floatsRead := c.accessor_unpack_floats(
			// 			accessor,
			// 			transmute([^]f32)raw_data(uvs),
			// 			numFloats,
			// 		)
			// 		assert(floatsRead == numFloats)
			// 	}

			// }
			// assert(len(positions) == len(normals) && len(normals) == len(uvs))
			// resize(&primInfo.vertices, len(positions))
			// for &vert, i in primInfo.vertices {
			// 	vert = {
			// 		pos  = positions[i],
			// 		norm = normals[i],
			// 		uv   = uvs[i],
			// 	}
			// }


			// if primitive.indices != nil {
			// 	resize(&primInfo.indices, primitive.indices.count)

			// 	intsRead := c.accessor_unpack_indices(
			// 		primitive.indices,
			// 		raw_data(primInfo.indices),
			// 		size_of(u32),
			// 		uint(len(primInfo.indices)),
			// 	)
			// 	assert(intsRead == primitive.indices.count)
			// }

			material := primitive.material

			if !material.has_pbr_metallic_roughness do continue

			metallicRoughness := material.pbr_metallic_roughness
			// primInfoImage.baseColorFactor = metallicRoughness.base_color_factor


			texView := metallicRoughness.base_color_texture
			if texView.texture == nil do texView = metallicRoughness.metallic_roughness_texture

			if texView.texture == nil {
				fmt.println("Warning: No texture found for primitive, skipping")
				continue
			}
			// assert(texView.texture != nil)

			texture := texView.texture
			image := texture.image_

			DESIRED_CHANNELS :: 4

			if image.uri != nil {
				modelDir := filepath.dir(path)
				uriNormalString := strings.clone_from_cstring(image.uri, context.temp_allocator)
				finalPath, joinErr := filepath.join(
					{modelDir, uriNormalString},
					context.temp_allocator,
				)
				ensure(joinErr == nil)
				finalPathCstring := strings.clone_to_cstring(finalPath, context.temp_allocator)
				assert(os.exists(finalPath))

				primInfoImage.data = stbImage.load(
					finalPathCstring,
					&primInfoImage.width,
					&primInfoImage.height,
					nil,
					DESIRED_CHANNELS,
				)


			} else if image.buffer_view != nil {
				view := image.buffer_view
				buffer := view.buffer

				dataPtr := ([^]u8)(buffer.data)
				offset := view.offset
				size := view.size
				startOfImage := mem.ptr_offset(dataPtr, offset)
				primInfoImage.data = stbImage.load_from_memory(
					startOfImage,
					i32(size),
					&primInfoImage.width,
					&primInfoImage.height,
					nil,
					DESIRED_CHANNELS,
				)
			}
			defer stbImage.image_free(primInfoImage.data)
			assert(primInfoImage.data != nil)
			assert(primInfoImage.width != 0)
			assert(primInfoImage.height != 0)
			primInfoImage.channels = DESIRED_CHANNELS

			if texture.sampler != nil {
				sampler := texture.sampler

				magFilter: vk.Filter = .LINEAR
				primInfoImage.magFilter = cgltf_filter_type_to_vk_filter(sampler.mag_filter)
				primInfoImage.minFilter = cgltf_filter_type_to_vk_filter(sampler.min_filter)
			}
			primitive_image_assert(primInfoImage)

			renderObj := RenderObject{}


			posAcc: ^c.accessor = nil
			normAcc: ^c.accessor = nil
			uvAcc: ^c.accessor = nil
			for attrib in primitive.attributes {
				#partial switch attrib.type {
				case .position:
					posAcc = attrib.data
				case .normal:
					normAcc = attrib.data
				case .texcoord:
					uvAcc = attrib.data
				}
			}
			assert(posAcc != nil)
			assert(normAcc != nil)
			assert(uvAcc != nil)
			vertexCount := posAcc.count
			assert(vertexCount == normAcc.count && normAcc.count == uvAcc.count)

			posBufferSize := vk.DeviceSize(vertexCount * size_of([3]f32))
			chk(
				vma.create_buffer(
					allocator,
					{sType = .BUFFER_CREATE_INFO, size = posBufferSize, usage = {.VERTEX_BUFFER}},
					{
						flags = {
							.Host_Access_Sequential_Write,
							.Host_Access_Allow_Transfer_Instead,
						},
						usage = .Auto,
					},
					&renderObj.primitive.posBuffer,
					&renderObj.primitive.posAlloc,
					nil,
				),
			)
			posPtr: rawptr
			chk(vma.map_memory(allocator, renderObj.primitive.posAlloc, &posPtr))
			floatsReadPos := c.accessor_unpack_floats(posAcc, cast([^]f32)posPtr, vertexCount * 3)
			assert(floatsReadPos == vertexCount * 3)
			vma.unmap_memory(allocator, renderObj.primitive.posAlloc)

			normBufferSize := vk.DeviceSize(vertexCount * 3 * size_of(f32))
			chk(
				vma.create_buffer(
					allocator,
					{sType = .BUFFER_CREATE_INFO, size = normBufferSize, usage = {.VERTEX_BUFFER}},
					{
						flags = {
							.Host_Access_Sequential_Write,
							.Host_Access_Allow_Transfer_Instead,
						},
						usage = .Auto,
					},
					&renderObj.primitive.normBuffer,
					&renderObj.primitive.normAlloc,
					nil,
				),
			)
			normPtr: rawptr
			chk(vma.map_memory(allocator, renderObj.primitive.normAlloc, &normPtr))

			floatsReadNorm := c.accessor_unpack_floats(
				normAcc,
				cast([^]f32)normPtr,
				vertexCount * 3,
			)
			assert(floatsReadNorm == vertexCount * 3)
			vma.unmap_memory(allocator, renderObj.primitive.normAlloc)

			uvBufferSize := vk.DeviceSize(vertexCount * 2 * size_of(f32))
			chk(
				vma.create_buffer(
					allocator,
					{sType = .BUFFER_CREATE_INFO, size = uvBufferSize, usage = {.VERTEX_BUFFER}},
					{
						flags = {
							.Host_Access_Sequential_Write,
							.Host_Access_Allow_Transfer_Instead,
						},
						usage = .Auto,
					},
					&renderObj.primitive.uvBuffer,
					&renderObj.primitive.uvAlloc,
					nil,
				),
			)

			uvPtr: rawptr
			chk(vma.map_memory(allocator, renderObj.primitive.uvAlloc, &uvPtr))
			floatsReadUv := c.accessor_unpack_floats(uvAcc, cast([^]f32)uvPtr, vertexCount * 2)
			assert(floatsReadUv == vertexCount * 2)
			vma.unmap_memory(allocator, renderObj.primitive.uvAlloc)

			if primitive.indices != nil {
				assert(primitive.indices.count < uint(max(GLTF_INDICES_TYPE_USED)))
				renderObj.primitive.indexCount = GLTF_INDICES_TYPE_USED(primitive.indices.count)

				indexBufferSize := size_of(GLTF_INDICES_TYPE_USED) * renderObj.primitive.indexCount
				chk(
					vma.create_buffer(
						allocator,
						{
							sType = .BUFFER_CREATE_INFO,
							size = vk.DeviceSize(indexBufferSize),
							usage = {.INDEX_BUFFER},
						},
						{
							flags = {
								.Host_Access_Sequential_Write,
								.Host_Access_Allow_Transfer_Instead,
							},
							usage = .Auto,
						},
						&renderObj.primitive.indexBuffer,
						&renderObj.primitive.indexAlloc,
						nil,
					),
				)
				indexPtr: ^u8
				chk(vma.map_memory(allocator, renderObj.primitive.indexAlloc, (^rawptr)(&indexPtr)))
				defer vma.unmap_memory(allocator, renderObj.primitive.indexAlloc)


				indicesRead := c.accessor_unpack_indices(
					primitive.indices,
					indexPtr,
					size_of(GLTF_INDICES_TYPE_USED),
					uint(renderObj.primitive.indexCount),
				)
				assert(indicesRead < uint(max(GLTF_INDICES_TYPE_USED)))
				assert(u32(indicesRead) == renderObj.primitive.indexCount)


			}

			renderObj.material.baseColorTexture = load_image(primInfoImage, cb)

			renderObj.material.baseColorFactor = metallicRoughness.base_color_factor
			#partial switch primitive.type {
			case .triangles:
				renderObj.primitive.topology = .TRIANGLE_LIST
			case:
				unreachable()
			}
			renderObj.primitive.transform = localMat
			append(&model.renderObjs, renderObj)


		}
	}

	return model
}
model_destroy :: proc(m: Model) {
	for obj in m.renderObjs {
		if obj.primitive.posBuffer != {} {
			vma.destroy_buffer(allocator, obj.primitive.posBuffer, obj.primitive.posAlloc)
		}
		if obj.primitive.normBuffer != {} {
			vma.destroy_buffer(allocator, obj.primitive.normBuffer, obj.primitive.normAlloc)
		}
		if obj.primitive.uvBuffer != {} {
			vma.destroy_buffer(allocator, obj.primitive.uvBuffer, obj.primitive.uvAlloc)
		}

		if obj.primitive.indexBuffer != {} {
			vma.destroy_buffer(allocator, obj.primitive.indexBuffer, obj.primitive.indexAlloc)
		}
		view := obj.material.baseColorTexture.descriptor.imageView
		if view != {} do vk.DestroyImageView(device, view, nil)

		sampler := obj.material.baseColorTexture.descriptor.sampler
		if sampler != {} do vk.DestroySampler(device, sampler, nil)


		image := obj.material.baseColorTexture.image
		if image != {} do vma.destroy_image(allocator, image, obj.material.baseColorTexture.allocation)

	}
	delete(m.renderObjs)

}
@(private)
cgltf_filter_type_to_vk_filter :: proc(t: c.filter_type) -> (vkT: vk.Filter) {
	// Odin switch cases do NOT fall through; each case must set vkT.
	switch t {
	case .linear_mipmap_linear, .linear, .linear_mipmap_nearest, .undefined:
		vkT = .LINEAR
	case .nearest, .nearest_mipmap_nearest, .nearest_mipmap_linear:
		vkT = .NEAREST
	}
	return vkT
}
@(private)
primitive_image_assert :: proc(pi: ImageLoaderInputs) {
	when ODIN_DEBUG {
		assert(pi.data != nil)
		assert(pi.width != 0)
		assert(pi.height != 0)
		assert(pi.channels != 0)
	}
}
Model :: struct {
	renderObjs: [dynamic]RenderObject,
}
RenderObject :: struct {
	primitive: GPUPrimitive,
	material:  GPUMaterial,
}
GPUMaterial :: struct {
	baseColorTexture: GPUTexture,
	baseColorFactor:  [4]f32,
}
GPU_MESH_MAX_DESCRIPTORS :: 5
GPUPrimitive :: struct {
	posBuffer:     vk.Buffer,
	posAlloc:      vma.Allocation,
	normBuffer:    vk.Buffer,
	normAlloc:     vma.Allocation,
	uvBuffer:      vk.Buffer,
	uvAlloc:       vma.Allocation,
	verticesCount: u32,
	indexBuffer:   vk.Buffer,
	indexAlloc:    vma.Allocation,
	indexCount:    u32,
	topology:      vk.PrimitiveTopology,
	transform:     matrix[4, 4]f32,
}
