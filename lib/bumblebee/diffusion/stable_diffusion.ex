defmodule Bumblebee.Diffusion.StableDiffusion do
  @moduledoc """
  High-level functions implementing tasks based on Stable Diffusion.
  """

  import Nx.Defn

  @doc ~S"""
  Performs end-to-end image generation based on the given prompt.

  ## Options

    * `:num_steps` - the number of denoising steps. More denoising
      steps usually lead to higher image quality at the expense of
      slower inference. Defaults to `50`

    * `:num_images_per_prompt` - the number of images to generate for
      each prompt. Defaults to `1`

    * `:guidance_scale` - the scale used for classifier-free diffusion
      guidance. Higher guidance scale makes the generated images more
      closely reflect the text prompt. This parameter corresponds to
      $\omega$ in Equation (2) of the [Imagen paper](https://arxiv.org/pdf/2205.11487.pdf).
      Defaults to `7.5`

    * `:seed` - a seed for the random number generator. Defaults to `0`

    * `:length` - the length to pad/truncate the prompts to. Fixing
      the length to a certain value allows for caching model compilation
      across different prompts. By default prompts are padded to
      match the longest one

    * `:defn_options` - the options for to JIT compilation. Defaults
      to `[]`

  """
  @spec text_to_image(
          model_triplet,
          model_triplet,
          model_triplet,
          Bumblebee.Tokenizer.t(),
          Bumblebee.Scheduler.t(),
          String.t() | list(String.t()),
          keyword()
        ) :: list(%{image: Nx.Tensor.t()})
        when model_triplet: {model :: Axon.t(), params :: map(), spec :: Bumblebee.ModelSpec.t()}
  def text_to_image(encoder, vae, unet, tokenizer, scheduler, prompt, opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :length,
        num_steps: 50,
        num_images_per_prompt: 1,
        guidance_scale: 7.5,
        seed: 0,
        defn_options: []
      ])

    prompts = List.wrap(prompt)
    batch_size = length(prompts)

    num_steps = opts[:num_steps]
    num_images_per_prompt = opts[:num_images_per_prompt]
    length = opts[:length]
    defn_options = opts[:defn_options]

    {encoder_model, encoder_params, _encoder_spec} = encoder
    {vae_model, vae_params, _vae_spec} = vae
    {unet_model, unet_params, unet_spec} = unet

    {_, encoder_predict} = Axon.build(encoder_model)
    {_, vae_predict} = Axon.build(vae_model)
    {_, unet_predict} = Axon.build(unet_model)

    prompts = List.duplicate("", batch_size) ++ prompts
    inputs = Bumblebee.apply_tokenizer(tokenizer, prompts, length: length)

    latents_shape =
      {batch_size * num_images_per_prompt, unet_spec.in_channels, unet_spec.sample_size,
       unet_spec.sample_size}

    scheduler_init = fn -> Bumblebee.scheduler_init(scheduler, num_steps, latents_shape) end
    scheduler_step = &Bumblebee.scheduler_step(scheduler, &1, &2, &3)

    images =
      Nx.Defn.jit(&text_to_image_impl/10, defn_options).(
        encoder_predict,
        encoder_params,
        unet_predict,
        unet_params,
        vae_predict,
        vae_params,
        scheduler_init,
        scheduler_step,
        inputs,
        opts
      )

    for idx <- 0..(batch_size - 1) do
      %{image: images[idx]}
    end
  end

  defnp text_to_image_impl(
          encoder_predict,
          encoder_params,
          unet_predict,
          unet_params,
          vae_predict,
          vae_params,
          scheduler_init,
          scheduler_step,
          inputs,
          opts \\ []
        ) do
    num_images_per_prompt = opts[:num_images_per_prompt]
    latents_shape = opts[:latents_shape]
    seed = opts[:seed]
    guidance_scale = opts[:guidance_scale]

    %{hidden_state: text_embeddings} = encoder_predict.(encoder_params, inputs)

    {_, seq_length, hidden_size} = Nx.shape(text_embeddings)

    text_embeddings =
      text_embeddings
      |> Nx.new_axis(1)
      |> Nx.tile([1, num_images_per_prompt, 1, 1])
      |> Nx.reshape({:auto, seq_length, hidden_size})

    {scheduler_state, timesteps} = scheduler_init.()

    key = Nx.Random.key(seed)
    {latents, _key} = Nx.Random.normal(key, shape: latents_shape)

    {_, latents, _, _} =
      while {scheduler_state, latents, text_embeddings, unet_params}, timestep <- timesteps do
        unet_inputs = %{
          "sample" => Nx.concatenate([latents, latents]),
          "timestep" => timestep,
          "encoder_hidden_state" => text_embeddings
        }

        %{sample: noise_pred} = unet_predict.(unet_params, unet_inputs)

        {noise_pred_unconditional, noise_pred_text} = split_in_half(noise_pred)

        noise_pred =
          noise_pred_unconditional + guidance_scale * (noise_pred_text - noise_pred_unconditional)

        {scheduler_state, latents} = scheduler_step.(scheduler_state, latents, noise_pred)

        {scheduler_state, latents, text_embeddings, unet_params}
      end

    latents = latents * (1 / 0.18215)

    %{sample: images} = vae_predict.(vae_params, latents)

    images
    |> Bumblebee.Utils.Image.from_continuous(-1, 1)
    |> Nx.transpose(axes: [0, 2, 3, 1])
  end

  defnp split_in_half(tensor) do
    batch_size = Nx.axis_size(tensor, 0)
    half_size = div(batch_size, 2)
    {tensor[0..(half_size - 1)//1], tensor[half_size..-1//1]}
  end
end